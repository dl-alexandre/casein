defmodule Casein.Mobile.TerminalChildGrantsTest do
  use Casein.DataCase, async: false

  import Ecto.Query

  alias Casein.DeviceLinks.Token
  alias Casein.Mobile.{TerminalChildGrant, TerminalChildGrants, TerminalSession}
  alias Casein.Repo

  setup do
    link = insert_device_link!()
    lease = insert_active_lease!(link.id)
    {:ok, link: link, lease: lease}
  end

  test "stores only a digest and begins use exactly once", %{lease: lease} do
    assert {:ok, %{token: raw, grant: issued}} =
             TerminalChildGrants.issue(lease, "topology-1")

    refute issued.token_hash == raw
    refute Repo.get!(TerminalChildGrant, issued.id).token_hash == raw

    context = context(issued)
    assert {:ok, begun} = TerminalChildGrants.begin_use(raw, context, "conn-1")
    assert begun.connection_generation == "conn-1"
    assert %DateTime{} = begun.begun_at
    assert :ok = TerminalChildGrants.authorize(begun, context, "conn-1")

    assert {:error, :grant_already_used} =
             TerminalChildGrants.begin_use(raw, context, "conn-2")

    assert TerminalChildGrants.revoke_for_lease(lease.id) == 1

    assert {:error, :grant_revoked} =
             TerminalChildGrants.authorize(begun, context, "conn-1")
  end

  test "wrong scope and malformed tokens fail closed", %{lease: lease} do
    assert {:ok, %{token: raw, grant: grant}} =
             TerminalChildGrants.issue(lease, "topology-1")

    assert {:error, :stale_grant} =
             TerminalChildGrants.begin_use(raw, %{context(grant) | pane_id: "%other"}, "conn-1")

    assert {:error, :stale_grant} =
             TerminalChildGrants.begin_use("unknown-token", context(grant), "conn-1")
  end

  test "expiry and revocation reject without exposing token details", %{lease: lease} do
    now = ~U[2026-08-05 12:00:00Z]

    assert {:ok, %{token: expired_raw, grant: expired}} =
             TerminalChildGrants.issue(lease, "topology-1", now: now, ttl_seconds: 1)

    assert {:error, :grant_expired} =
             TerminalChildGrants.begin_use(
               expired_raw,
               context(expired),
               "conn-expired",
               now: DateTime.add(now, 2, :second)
             )

    assert {:ok, %{token: raw, grant: grant}} =
             TerminalChildGrants.issue(lease, "topology-1", now: now)

    assert TerminalChildGrants.revoke_for_lease(lease.id, now: now) == 2

    assert {:error, :grant_revoked} =
             TerminalChildGrants.begin_use(raw, context(grant), "conn-revoked", now: now)
  end

  test "refresh revokes the prior grant and returns a distinct raw token", %{lease: lease} do
    assert {:ok, %{token: first_raw, grant: first}} =
             TerminalChildGrants.issue(lease, "topology-1")

    assert {:ok, %{token: second_raw, grant: second}} =
             TerminalChildGrants.refresh(lease, "topology-2")

    refute first_raw == second_raw
    assert %DateTime{} = Repo.get!(TerminalChildGrant, first.id).revoked_at
    assert is_nil(Repo.get!(TerminalChildGrant, second.id).revoked_at)
    assert second.topology_generation == "topology-2"
  end

  test "an expired connection can refresh and reconnect without killing its lease", %{
    lease: lease
  } do
    now = ~U[2026-08-05 12:00:00Z]

    assert {:ok, %{token: old_raw, grant: old}} =
             TerminalChildGrants.refresh(lease, "topology-1", now: now, ttl_seconds: 1)

    assert {:error, :grant_expired} =
             TerminalChildGrants.begin_use(
               old_raw,
               context(old),
               "conn-old",
               now: DateTime.add(now, 2, :second)
             )

    assert {:ok, %{token: fresh_raw, grant: fresh}} =
             TerminalChildGrants.refresh(lease, "topology-1", now: DateTime.add(now, 2, :second))

    assert {:ok, begun} =
             TerminalChildGrants.begin_use(
               fresh_raw,
               context(fresh),
               "conn-new",
               now: DateTime.add(now, 2, :second)
             )

    assert begun.connection_generation == "conn-new"
    assert %DateTime{} = Repo.get!(TerminalChildGrant, old.id).revoked_at
  end

  test "concurrent begin-use has one winner", %{lease: lease} do
    assert {:ok, %{token: raw, grant: grant}} =
             TerminalChildGrants.issue(lease, "topology-1")

    context = context(grant)

    results =
      1..2
      |> Enum.map(fn sequence ->
        Task.async(fn -> TerminalChildGrants.begin_use(raw, context, "conn-#{sequence}") end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :grant_already_used})) == 1
  end

  test "concurrent refresh serializes to one active authority", %{lease: lease} do
    results =
      1..2
      |> Enum.map(fn sequence ->
        Task.async(fn -> TerminalChildGrants.refresh(lease, "topology-#{sequence}") end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))

    active =
      TerminalChildGrant
      |> where([grant], grant.lease_id == ^lease.id and is_nil(grant.revoked_at))
      |> Repo.all()

    assert [winner] = active

    earlier =
      results
      |> Enum.map(fn {:ok, %{grant: grant}} -> grant end)
      |> Enum.reject(&(&1.id == winner.id))
      |> List.first()

    assert %DateTime{} = Repo.get!(TerminalChildGrant, earlier.id).revoked_at
  end

  defp context(grant) do
    Map.take(grant, [
      :user_id,
      :device_link_id,
      :origin_id,
      :origin_generation,
      :workspace_id,
      :lease_id,
      :lifecycle_generation,
      :sid,
      :tmux_session,
      :pane_id,
      :pane_role,
      :topology_generation
    ])
  end

  defp insert_device_link! do
    %Token{}
    |> Token.changeset(%{
      origin_id: "origin-1",
      origin_name: "Devbox",
      subject_id: "user-1",
      subject_role: "owner",
      token_hash: String.duplicate("b", 64),
      resource_kind: "workspace",
      resource_id: "workspace-id",
      capabilities: ["phoenix_socket"]
    })
    |> Repo.insert!()
  end

  defp insert_active_lease!(device_link_id) do
    sid = "mob-" <> Ecto.UUID.generate()

    lease =
      %TerminalSession{}
      |> TerminalSession.create_changeset(%{
        user_id: "user-1",
        device_link_id: device_link_id,
        origin_id: "origin-1",
        origin_generation: "origin-generation-1",
        workspace_id: "workspace-id",
        workspace_key: "workspace",
        workspace_root: "/tmp/workspace",
        request_id: Ecto.UUID.generate(),
        request_fingerprint: String.duplicate("a", 64),
        sid: sid,
        tmux_session: Casein.Terminals.tmux_session_name("workspace", sid),
        pane_role: "mobile_terminal",
        lifecycle_generation: Ecto.UUID.generate(),
        state: "provisioning",
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      })
      |> Repo.insert!()

    lease
    |> TerminalSession.transition_changeset(%{
      state: "active",
      pane_id: "%1",
      tmux_native_id: "$1",
      tmux_lease_marker: lease.lifecycle_generation
    })
    |> Repo.update!()
  end
end
