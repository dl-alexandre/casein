defmodule Casein.Mobile.TerminalSessionsTest do
  use Casein.DataCase, async: false

  alias Casein.Mobile.{TerminalSession, TerminalSessions}
  alias Casein.Repo

  defmodule Tmux do
    def start_link,
      do:
        Agent.start_link(
          fn ->
            %{
              sessions: %{},
              kills: [],
              ensure_error: nil,
              ensure_count: 0,
              kill_error: nil,
              kill_blocker: nil
            }
          end,
          name: __MODULE__
        )

    def ensure_session(session, cwd) do
      Agent.get_and_update(__MODULE__, fn
        %{ensure_error: nil} = state ->
          state =
            state
            |> Map.update!(:ensure_count, &(&1 + 1))
            |> put_in([:sessions, session], %{cwd: cwd, pane: %{id: "%1"}})

          {:ok, state}

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
      {blocker, error} = Agent.get(__MODULE__, &{&1.kill_blocker, &1.kill_error})

      if blocker do
        lease = Casein.Repo.get_by!(Casein.Mobile.TerminalSession, tmux_session: session)
        send(blocker, {:kill_started, self(), session, lease.state})

        receive do
          :continue_kill -> :ok
        end
      end

      if error do
        Agent.update(__MODULE__, &%{&1 | kill_error: nil})
        {:error, error}
      else
        Agent.update(__MODULE__, fn state ->
          state
          |> update_in([:kills], &[session | &1])
          |> update_in([:sessions], &Map.delete(&1, session))
        end)

        :ok
      end
    end

    def session_exists?(session),
      do: Agent.get(__MODULE__, &Map.has_key?(&1.sessions, session))

    def kills, do: Agent.get(__MODULE__, & &1.kills)
    def ensure_count, do: Agent.get(__MODULE__, & &1.ensure_count)
    def ensure_error(reason), do: Agent.update(__MODULE__, &%{&1 | ensure_error: reason})
    def kill_error(reason), do: Agent.update(__MODULE__, &%{&1 | kill_error: reason})
    def block_kill(pid), do: Agent.update(__MODULE__, &%{&1 | kill_blocker: pid})

    def replace_pane(session, pane_id, role) do
      Agent.update(
        __MODULE__,
        &put_in(&1, [:sessions, session, :pane], %{id: pane_id, role: role})
      )
    end
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

  test "same device request with changed workspace key or root fails closed" do
    attrs = attrs()
    assert {:ok, _} = TerminalSessions.create(attrs, tmux: Tmux)

    assert {:error, :idempotency_key_reused} =
             TerminalSessions.create(%{attrs | workspace_key: "other-workspace"}, tmux: Tmux)

    assert {:error, :idempotency_key_reused} =
             TerminalSessions.create(%{attrs | workspace_root: "/tmp/other-workspace"},
               tmux: Tmux
             )

    assert Repo.aggregate(TerminalSession, :count) == 1
  end

  test "concurrent same-key create has one provision and one created audit" do
    attrs = attrs()

    tasks = for _ <- 1..2, do: Task.async(fn -> TerminalSessions.create(attrs, tmux: Tmux) end)
    assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &Task.await(&1, 5_000))
    assert first.id == second.id
    assert Tmux.ensure_count() == 1

    created =
      Casein.Audit.list(limit: 20)
      |> Enum.count(&(&1.target_ref == first.id and &1.action == "mobile.terminal_created"))

    assert created == 1
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
               not Map.has_key?(metadata, :tmux_session) and
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

    actions =
      Casein.Audit.list(limit: 20)
      |> Enum.filter(&(&1.target_ref == lease.id))
      |> Enum.map(& &1.action)

    assert "mobile.terminal_expired" in actions
    refute "mobile.terminal_deleted" in actions
  end

  test "deleting is committed before exact external teardown and blocks concurrent observers" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.block_kill(self())
    tmux_session = lease.tmux_session

    task = Task.async(fn -> TerminalSessions.delete(lease.id, tmux: Tmux) end)
    assert_receive {:kill_started, kill_pid, ^tmux_session, "deleting"}

    send(kill_pid, :continue_kill)
    assert {:ok, deleted} = Task.await(task, 5_000)
    assert deleted.state == "deleted"
  end

  test "pane replacement fails closed before exact teardown" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.replace_pane(lease.tmux_session, "%replacement", lease.pane_role)

    assert {:error, :pane_identity_mismatch} = TerminalSessions.delete(lease.id, tmux: Tmux)
    assert Repo.get!(TerminalSession, lease.id).state == "deleting"
    assert Tmux.session_exists?(lease.tmux_session)
    assert Tmux.kills() == []
  end

  test "pane role drift fails closed before exact teardown" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.replace_pane(lease.tmux_session, lease.pane_id, "operator")

    assert {:error, :pane_role_mismatch} = TerminalSessions.delete(lease.id, tmux: Tmux)
    assert Repo.get!(TerminalSession, lease.id).state == "deleting"
    assert Tmux.session_exists?(lease.tmux_session)
    assert Tmux.kills() == []
  end

  test "partial external teardown leaves a durable deleting fence and retries exactly" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.kill_error(:temporarily_unavailable)

    assert {:error, :temporarily_unavailable} = TerminalSessions.delete(lease.id, tmux: Tmux)
    assert Repo.get!(TerminalSession, lease.id).state == "deleting"
    assert Tmux.session_exists?(lease.tmux_session)

    assert {:ok, deleted} = TerminalSessions.delete(lease.id, tmux: Tmux)
    assert deleted.state == "deleted"
    assert Tmux.kills() == [lease.tmux_session]
  end

  test "reaper retry of an explicit delete preserves deleted rather than expired audit semantics" do
    now = ~U[2026-08-05 10:00:00Z]

    assert {:ok, lease} =
             TerminalSessions.create(attrs(), tmux: Tmux, now: now, ttl_seconds: 60)

    Tmux.kill_error(:temporarily_unavailable)

    assert {:error, :temporarily_unavailable} = TerminalSessions.delete(lease.id, tmux: Tmux)
    assert Repo.get!(TerminalSession, lease.id).state == "deleting"

    assert [{:ok, deleted}] =
             TerminalSessions.reconcile_due(tmux: Tmux, now: DateTime.add(now, 1, :second))

    assert deleted.state == "deleted"

    actions =
      Casein.Audit.list(limit: 20)
      |> Enum.filter(&(&1.target_ref == lease.id))
      |> Enum.map(& &1.action)

    assert "mobile.terminal_deleted" in actions
    refute "mobile.terminal_expired" in actions
  end

  test "startup reconciliation removes an exact stale archive before provisioning" do
    lease = insert_provisioning!()
    Casein.Terminals.ScrollbackArchive.ensure_table!()
    :ok = Casein.Terminals.ScrollbackArchive.put(lease.tmux_session, "must-not-survive")
    assert Casein.Terminals.ScrollbackArchive.present?(lease.tmux_session)

    assert [{:ok, active}] = TerminalSessions.reconcile_startup(tmux: Tmux)
    assert active.id == lease.id
    refute Casein.Terminals.ScrollbackArchive.present?(lease.tmux_session)
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

  defp insert_provisioning! do
    attrs = attrs()
    sid = "mob-" <> Ecto.UUID.generate()

    %TerminalSession{}
    |> TerminalSession.create_changeset(
      Map.merge(attrs, %{
        request_fingerprint: String.duplicate("a", 64),
        sid: sid,
        tmux_session: Casein.Terminals.tmux_session_name(attrs.workspace_key, sid),
        pane_role: "mobile_terminal",
        lifecycle_generation: Ecto.UUID.generate(),
        state: "provisioning",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })
    )
    |> Repo.insert!()
  end
end
