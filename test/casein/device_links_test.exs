defmodule Casein.DeviceLinksTest do
  use Casein.DataCase, async: false

  alias Casein.DeviceLinks
  alias Casein.DeviceLinks.Token
  alias Casein.Mobile.{TerminalSession, TerminalStream}
  alias Casein.Workspace
  alias Casein.Repo

  defmodule OwnedSource do
    def get("missing", _auth), do: {:error, :not_found}

    def get(id, _auth),
      do: {:ok, %Workspace{id: id, name: "Workspace #{id}", user: "owner", status: :running}}
  end

  setup do
    prev_source = Application.get_env(:casein, :workspace_source)
    Application.put_env(:casein, :workspace_source, OwnedSource)

    on_exit(fn -> restore(:workspace_source, prev_source) end)

    :ok
  end

  test "creates a hashed persistent token with expires_at and verifies socket claims" do
    assert {:ok, %{token: raw_token, link: link}} =
             DeviceLinks.create_from_pairing_claims(owner_claims(), %{
               "device_name" => "Pixel Tablet",
               "platform" => "android"
             })

    refute raw_token == link.token_hash
    assert %DateTime{} = link.expires_at
    assert DateTime.compare(link.expires_at, DateTime.utc_now()) == :gt
    assert link.resource_kind == "workspace"
    assert link.resource_id == "ws-1"
    assert link.resource_label == "Workspace ws-1"
    assert link.device_name == "Pixel Tablet"
    assert link.platform == "android"

    assert {:ok, claims} = DeviceLinks.verify_token(raw_token)
    assert claims.id == "owner"
    assert claims.email == "owner@example.com"
    assert claims.role == :owner
    assert claims.workspace_id == "ws-1"
    assert claims.resource_kind == "workspace"
    assert claims.device_link_id == link.id
    assert "casein.session" in claims.capabilities

    assert %Token{last_seen_at: %DateTime{}} = Repo.get!(Token, link.id)
  end

  test "issues a persistent token for any authenticated peer (flat peer model)" do
    claims = %{
      owner_claims()
      | id: "peer",
        username: "peer",
        email: "peer@example.com"
    }

    assert {:ok, %{token: raw_token}} = DeviceLinks.create_from_pairing_claims(claims, %{})
    assert is_binary(raw_token) and raw_token != ""
  end

  test "revoked token no longer verifies" do
    assert {:ok, %{token: raw_token, link: link}} =
             DeviceLinks.create_from_pairing_claims(owner_claims(), %{})

    assert {:ok, _claims} = DeviceLinks.verify_token(raw_token)
    assert :ok = DeviceLinks.subscribe_revocation(link.id)
    link_id = link.id
    lease = insert_active_lease!(link.id)
    stream = start_supervised!({TerminalStream, lease_id: lease.id})
    assert {:ok, _} = TerminalStream.subscribe(stream, "device-revoke")
    assert {:ok, _} = TerminalStream.append(stream, "before-revoke")
    assert_receive {:mobile_terminal_output, _}

    assert {:ok, _link} = DeviceLinks.revoke_token(raw_token)
    assert TerminalStream.snapshot(stream).cutoff == "grant_revoked"
    assert {:error, "grant_revoked"} = TerminalStream.append(stream, "after-return")
    assert_receive {:device_link_revoked, ^link_id}
    assert {:error, :revoked} = DeviceLinks.verify_token(raw_token)
  end

  defp insert_active_lease!(device_link_id) do
    sid = "mob-" <> Ecto.UUID.generate()

    lease =
      %TerminalSession{}
      |> TerminalSession.create_changeset(%{
        user_id: "owner",
        device_link_id: device_link_id,
        origin_id: Casein.Origin.id(),
        origin_generation: Casein.Origin.incarnation(),
        workspace_id: "ws-1",
        workspace_key: "ws-1",
        workspace_root: "/tmp/ws-1",
        request_id: Ecto.UUID.generate(),
        request_fingerprint: String.duplicate("a", 64),
        sid: sid,
        tmux_session: Casein.Terminals.tmux_session_name("ws-1", sid),
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

  test "missing workspace is surfaced" do
    claims = %{owner_claims() | workspace_id: "missing"}

    assert {:error, :not_found} = DeviceLinks.create_from_pairing_claims(claims, %{})
  end

  test "list_for_subject returns active links ordered by recency" do
    assert {:ok, %{link: first}} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})
    assert {:ok, %{link: second}} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})

    Repo.update!(Ecto.Changeset.change(first, last_seen_at: ~U[2026-01-01 00:00:00.000000Z]))
    Repo.update!(Ecto.Changeset.change(second, last_seen_at: ~U[2026-06-01 00:00:00.000000Z]))

    assert [newest, older] = DeviceLinks.list_for_subject("owner")
    assert newest.id == second.id
    assert older.id == first.id
  end

  test "revoke_all_for_subject revokes every active link" do
    assert {:ok, _} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})
    assert {:ok, _} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})

    assert DeviceLinks.revoke_all_for_subject("owner") == 2
    assert DeviceLinks.list_for_subject("owner") == []
  end

  test "rotate racing revoke-all never mints authority after revocation returns" do
    for sequence <- 1..12 do
      subject = "rotate-race-#{sequence}"
      claims = %{owner_claims() | id: subject, username: subject, email: "#{subject}@example.com"}
      assert {:ok, %{token: raw}} = DeviceLinks.create_from_pairing_claims(claims, %{})
      parent = self()

      rotate =
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> DeviceLinks.rotate_token(raw))
        end)

      revoke =
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> DeviceLinks.revoke_all_for_subject(subject))
        end)

      assert_receive {:ready, rotate_pid}
      assert_receive {:ready, revoke_pid}
      send(rotate_pid, :go)
      send(revoke_pid, :go)

      rotate_result = Task.await(rotate, 5_000)
      assert Task.await(revoke, 5_000) in [1, 2]

      case rotate_result do
        {:ok, %{token: replacement}} ->
          assert {:error, :revoked} = DeviceLinks.verify_token(replacement)

        {:error, reason} ->
          assert reason in [:revoked, :invalid_token]
      end
    end
  end

  test "ttl_seconds honors application config" do
    prev = Application.get_env(:casein, :device_link_ttl_seconds)
    Application.put_env(:casein, :device_link_ttl_seconds, 120)

    on_exit(fn -> restore(:device_link_ttl_seconds, prev) end)

    before = DateTime.utc_now()

    assert {:ok, %{link: link}} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})
    assert DateTime.diff(link.expires_at, before, :second) in 115..125
  end

  test "rotate_token mints a new credential and revokes the old atomically" do
    {:ok, %{token: old_token, link: old_link}} =
      DeviceLinks.create_from_pairing_claims(owner_claims(), %{"platform" => "ios"})

    assert {:ok, %{token: new_token, link: new_link}} = DeviceLinks.rotate_token(old_token)

    refute new_token == old_token
    refute new_link.id == old_link.id
    # Provenance carries over; old token is revoked, new one verifies.
    assert new_link.platform == "ios"
    assert new_link.resource_id == "ws-1"
    assert {:ok, %{workspace_id: "ws-1"}} = DeviceLinks.verify_token(new_token)
    assert {:error, :revoked} = DeviceLinks.verify_token(old_token)
    assert %Token{revoked_at: %DateTime{}} = Repo.get!(Token, old_link.id)
  end

  test "concurrent rotations have exactly one winner" do
    assert {:ok, %{token: raw}} = DeviceLinks.create_from_pairing_claims(owner_claims(), %{})
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> DeviceLinks.rotate_token(raw))
        end)
      end

    pids =
      for _ <- 1..2,
          do:
            (
              assert_receive {:ready, pid}
              pid
            )

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :revoked})) == 1
  end

  test "rotate_token refuses a revoked token" do
    {:ok, %{token: raw_token}} = DeviceLinks.create_from_pairing_claims(owner_claims())
    {:ok, _} = DeviceLinks.revoke_token(raw_token)

    assert {:error, :revoked} = DeviceLinks.rotate_token(raw_token)
  end

  test "rotate_token rejects an unknown token" do
    assert {:error, :invalid_token} = DeviceLinks.rotate_token("nope")
    assert {:error, :missing} = DeviceLinks.rotate_token("   ")
  end

  defp owner_claims do
    %{
      id: "owner",
      username: "owner",
      email: "owner@example.com",
      role: :owner,
      workspace_id: "ws-1"
    }
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)
end
