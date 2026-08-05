defmodule Casein.Mobile.TerminalSessionsTest do
  use Casein.DataCase, async: false

  alias Casein.Mobile.{TerminalSession, TerminalSessions}
  alias Casein.Repo

  defmodule Tmux do
    def start_link,
      do:
        Agent.start_link(fn -> %{sessions: %{}, kills: [], ensure_error: nil} end,
          name: __MODULE__
        )

    def ensure_session(session, cwd) do
      Agent.get_and_update(__MODULE__, fn
        %{ensure_error: nil} = state ->
          {:ok, put_in(state, [:sessions, session], %{cwd: cwd, pane: %{id: "%1"}})}

        %{ensure_error: reason} = state ->
          {{:error, reason}, state}
      end)
    end

    def list_session_panes(session) do
      Agent.get(__MODULE__, fn state ->
        case get_in(state, [:sessions, session, :pane]) do
          nil -> []
          pane -> [pane]
        end
      end)
    end

    def set_pane_role(session, pane_id, role) do
      Agent.update(__MODULE__, fn state ->
        update_in(state, [:sessions, session, :pane], &Map.merge(&1, %{id: pane_id, role: role}))
      end)

      :ok
    end

    def kill(session) do
      Agent.update(__MODULE__, fn state ->
        state
        |> update_in([:kills], &[session | &1])
        |> update_in([:sessions], &Map.delete(&1, session))
      end)

      :ok
    end

    def session_exists?(session),
      do: Agent.get(__MODULE__, &Map.has_key?(&1.sessions, session))

    def kills, do: Agent.get(__MODULE__, & &1.kills)
    def ensure_error(reason), do: Agent.update(__MODULE__, &%{&1 | ensure_error: reason})
  end

  setup do
    start_supervised!(%{id: Tmux, start: {Tmux, :start_link, []}})
    :ok
  end

  test "create is server-owned and same request is idempotent" do
    attrs = attrs()

    assert {:ok, first} = TerminalSessions.create(attrs, tmux: Tmux)
    assert first.state == "active"
    assert first.pane_id == "%1"
    assert first.pane_role == "mobile_terminal"
    assert String.starts_with?(first.sid, "mob-")
    assert first.tmux_session == Casein.Terminals.tmux_session_name("workspace", first.sid)

    assert {:ok, replay} = TerminalSessions.create(attrs, tmux: Tmux)
    assert replay.id == first.id
    assert Repo.aggregate(TerminalSession, :count) == 1
  end

  test "same device request with changed authoritative scope fails closed" do
    attrs = attrs()
    assert {:ok, _} = TerminalSessions.create(attrs, tmux: Tmux)

    assert {:error, :idempotency_key_reused} =
             TerminalSessions.create(%{attrs | origin_generation: "origin-generation-2"},
               tmux: Tmux
             )

    assert Repo.aggregate(TerminalSession, :count) == 1
  end

  test "delete is exact, ordered by authoritative identity, and idempotent" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)

    assert {:ok, deleted} = TerminalSessions.delete(lease.id, tmux: Tmux)
    assert deleted.state == "deleted"
    refute Tmux.session_exists?(lease.tmux_session)
    assert Tmux.kills() == [lease.tmux_session]

    assert {:ok, same} = TerminalSessions.delete(lease.id, tmux: Tmux)
    assert same.id == deleted.id
    assert Tmux.kills() == [lease.tmux_session]

    events =
      Casein.Audit.list(limit: 20)
      |> Enum.filter(&(&1.target_ref == lease.id))

    assert Enum.map(events, & &1.action) |> Enum.sort() ==
             ["mobile.terminal_created", "mobile.terminal_deleted"]

    assert Enum.all?(events, fn event ->
             metadata = event.metadata

             Map.has_key?(metadata, :terminal_id) and
               not Map.has_key?(metadata, :input) and
               not Map.has_key?(metadata, :output) and
               not Map.has_key?(metadata, :command)
           end)
  end

  test "expired leases are reaped without deriving a namespace prefix" do
    now = ~U[2026-08-05 10:00:00Z]
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux, now: now, ttl_seconds: 1)

    assert [{:ok, deleted}] =
             TerminalSessions.reconcile_due(tmux: Tmux, now: DateTime.add(now, 2, :second))

    assert deleted.state == "deleted"
    assert Tmux.kills() == [lease.tmux_session]
  end

  test "retryable tmux failure preserves one provisioning identity for startup reconciliation" do
    attrs = attrs()
    Tmux.ensure_error(:temporarily_unavailable)

    assert {:error, :temporarily_unavailable} = TerminalSessions.create(attrs, tmux: Tmux)
    [pending] = Repo.all(TerminalSession)
    assert pending.state == "provisioning"
    assert pending.failure_code =~ "temporarily_unavailable"

    Tmux.ensure_error(nil)
    assert [{:ok, active}] = TerminalSessions.reconcile_startup(tmux: Tmux)
    assert active.id == pending.id
    assert active.state == "active"
    assert Repo.aggregate(TerminalSession, :count) == 1
  end

  test "schema rejects client-like non-mobile identities" do
    changeset =
      TerminalSession.create_changeset(
        %TerminalSession{},
        Map.merge(attrs(), %{
          sid: "operator",
          request_fingerprint: String.duplicate("a", 64),
          tmux_session: "casein_workspace_operator",
          lifecycle_generation: Ecto.UUID.generate(),
          state: "provisioning",
          expires_at: DateTime.utc_now(),
          pane_role: "mobile_terminal"
        })
      )

    refute changeset.valid?
    assert "has invalid format" in errors_on(changeset).sid
  end

  test "create rejects relative roots, missing identity, and client-selected excessive TTL before tmux" do
    assert {:error, :invalid_create_attrs} =
             TerminalSessions.create(%{attrs() | workspace_root: "../operator"}, tmux: Tmux)

    assert {:error, :invalid_create_attrs} =
             TerminalSessions.create(%{attrs() | device_link_id: ""}, tmux: Tmux)

    assert {:error, :invalid_ttl} =
             TerminalSessions.create(attrs(), tmux: Tmux, ttl_seconds: 3_601)

    assert Repo.aggregate(TerminalSession, :count) == 0
  end

  defp attrs do
    %{
      user_id: "user-1",
      device_link_id: "device-1",
      origin_id: "origin-1",
      origin_generation: "origin-generation-1",
      workspace_id: "workspace-id",
      workspace_key: "workspace",
      workspace_root: "/tmp/workspace",
      request_id: Ecto.UUID.generate()
    }
  end
end
