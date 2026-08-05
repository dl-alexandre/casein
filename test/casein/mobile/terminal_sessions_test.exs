defmodule Casein.Mobile.TerminalSessionsTest do
  use Casein.DataCase, async: false

  alias Casein.Mobile.{TerminalSession, TerminalSessions}
  alias Casein.Repo

  import ExUnit.CaptureLog

  defmodule SessionModule do
    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def ensure_started(workspace, sid, loc, opts) do
      Agent.update(__MODULE__, &[{workspace, sid, loc, opts} | &1])
      {:ok, self()}
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

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
              kill_blocker: nil,
              provision_blocker: nil,
              disappear_on_list: false,
              provision_topology: :single,
              next_native_id: 1,
              replace_on_kill: false
            }
          end,
          name: __MODULE__
        )

    def ensure_session(session, cwd) do
      if blocker = Agent.get(__MODULE__, & &1.provision_blocker) do
        send(blocker, {:provision_started, self(), session})

        receive do
          :continue_provision -> :ok
        end
      end

      Agent.get_and_update(__MODULE__, fn
        %{ensure_error: nil} = state ->
          pane =
            case state.provision_topology do
              :single -> %{id: "%1"}
              :empty -> nil
              :missing_id -> %{}
              :multiple -> [%{id: "%1"}, %{id: "%2"}]
            end

          native_id = "$#{state.next_native_id}"

          state =
            state
            |> Map.update!(:ensure_count, &(&1 + 1))
            |> Map.update!(:next_native_id, &(&1 + 1))
            |> put_in([:sessions, session], %{
              cwd: cwd,
              pane: pane,
              native_id: native_id,
              marker: nil
            })

          {:ok, state}

        %{ensure_error: reason} = state ->
          {{:error, reason}, state}
      end)
    end

    def list_session_panes(session) do
      Agent.get_and_update(__MODULE__, fn state ->
        if state.disappear_on_list and Map.has_key?(state.sessions, session) do
          {[], %{state | sessions: Map.delete(state.sessions, session), disappear_on_list: false}}
        else
          panes =
            case get_in(state, [:sessions, session, :pane]) do
              nil -> []
              panes when is_list(panes) -> panes
              pane -> [pane]
            end

          {panes, state}
        end
      end)
    end

    def set_pane_role(session, pane_id, role) do
      Agent.update(__MODULE__, fn state ->
        update_in(state, [:sessions, session, :pane], &Map.merge(&1, %{id: pane_id, role: role}))
      end)

      :ok
    end

    def set_mobile_terminal_identity(session, marker) do
      Agent.get_and_update(__MODULE__, fn state ->
        case get_in(state, [:sessions, session]) do
          nil ->
            {{:error, :not_found}, state}

          current ->
            updated = Map.put(current, :marker, marker)
            identity = %{session_id: current.native_id, marker: marker}
            {{:ok, identity}, put_in(state, [:sessions, session], updated)}
        end
      end)
    end

    def mobile_terminal_identity(session) do
      Agent.get(__MODULE__, fn state ->
        case get_in(state, [:sessions, session]) do
          nil -> {:error, :not_found}
          current -> {:ok, %{session_id: current.native_id, marker: current.marker || ""}}
        end
      end)
    end

    def kill_mobile_terminal(session, native_id, marker) do
      if blocker = Agent.get(__MODULE__, & &1.kill_blocker) do
        lease = Casein.Repo.get_by!(Casein.Mobile.TerminalSession, tmux_session: session)
        send(blocker, {:kill_started, self(), session, lease.state})

        receive do
          :continue_kill -> :ok
        end
      end

      Agent.get_and_update(__MODULE__, fn state ->
        state = maybe_replace_at_kill(state, session)
        current = get_in(state, [:sessions, session])

        cond do
          state.kill_error ->
            {{:error, state.kill_error}, %{state | kill_error: nil}}

          is_nil(current) ->
            {{:error, :not_found}, state}

          current.native_id != native_id or current.marker != marker ->
            {{:error, :mobile_terminal_identity_mismatch}, state}

          true ->
            next =
              state
              |> update_in([:kills], &[session | &1])
              |> update_in([:sessions], &Map.delete(&1, session))

            {:ok, next}
        end
      end)
    end

    defp maybe_replace_at_kill(%{replace_on_kill: true} = state, session) do
      native_id = "$#{state.next_native_id}"

      state
      |> Map.put(:replace_on_kill, false)
      |> Map.update!(:next_native_id, &(&1 + 1))
      |> put_in([:sessions, session], %{
        cwd: "/tmp/replacement",
        pane: %{id: "%replacement", role: "operator"},
        native_id: native_id,
        marker: nil
      })
    end

    defp maybe_replace_at_kill(state, _session), do: state

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

    def provision_topology(topology),
      do: Agent.update(__MODULE__, &%{&1 | provision_topology: topology})

    def replace_on_kill, do: Agent.update(__MODULE__, &%{&1 | replace_on_kill: true})

    def block_kill(pid), do: Agent.update(__MODULE__, &%{&1 | kill_blocker: pid})
    def block_provision(pid), do: Agent.update(__MODULE__, &%{&1 | provision_blocker: pid})

    def external_remove(session) do
      Agent.update(
        __MODULE__,
        &update_in(&1, [:sessions], fn sessions -> Map.delete(sessions, session) end)
      )
    end

    def disappear_on_next_list do
      Agent.update(__MODULE__, &%{&1 | disappear_on_list: true})
    end

    def replace_pane(session, pane_id, role) do
      Agent.update(
        __MODULE__,
        &put_in(&1, [:sessions, session, :pane], %{id: pane_id, role: role})
      )
    end
  end

  defmodule TerminalControl do
    def start_link do
      Agent.start_link(fn -> %{stop_blocker: nil} end, name: __MODULE__)
    end

    def stop_shell_owner(_workspace_id, _sid), do: :ok

    def stop_session_exact(workspace_key, sid) do
      if blocker = Agent.get(__MODULE__, & &1.stop_blocker) do
        send(blocker, {:exact_stop_started, self(), workspace_key, sid})

        receive do
          :continue_exact_stop -> :ok
        end
      else
        :ok
      end
    end

    def block_stop(pid), do: Agent.update(__MODULE__, &%{&1 | stop_blocker: pid})
  end

  setup do
    start_supervised!(%{id: Tmux, start: {Tmux, :start_link, []}})
    start_supervised!(%{id: TerminalControl, start: {TerminalControl, :start_link, []}})
    start_supervised!(%{id: SessionModule, start: {SessionModule, :start_link, []}})
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
    assert first.tmux_native_id == "$1"
    assert first.tmux_lease_marker == first.lifecycle_generation

    assert {:ok, replay} = TerminalSessions.create(attrs, tmux: Tmux)
    assert replay.id == first.id
    assert Repo.aggregate(TerminalSession, :count) == 1
  end

  test "authoritative mobile PTY path always requests ephemeral archive disposition" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    assert {:ok, _pid} = TerminalSessions.ensure_pty(lease.id, session_module: SessionModule)

    assert [{"workspace", sid, {:local, "/tmp/workspace"}, [archive: :ephemeral]}] =
             SessionModule.calls()

    assert sid == lease.sid
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

  test "provision and delete of the same lease serialize on one lifecycle lock" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.external_remove(lease.tmux_session)

    from(s in TerminalSession, where: s.id == ^lease.id)
    |> Repo.update_all(
      set: [
        state: "provisioning",
        pane_id: nil,
        tmux_native_id: nil,
        tmux_lease_marker: nil
      ]
    )

    Tmux.block_provision(self())

    provision_task = Task.async(fn -> TerminalSessions.reconcile_startup(tmux: Tmux) end)
    assert_receive {:provision_started, provision_pid, tmux_session}
    assert lease.tmux_session == tmux_session

    delete_task = Task.async(fn -> TerminalSessions.delete(lease.id, tmux: Tmux) end)
    assert Task.yield(delete_task, 100) == nil

    send(provision_pid, :continue_provision)
    assert [{:ok, active}] = Task.await(provision_task, 5_000)
    assert active.state == "active"
    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.state == "deleted"
    assert Tmux.kills() == [tmux_session]
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

  test "concurrent deletes serialize exact teardown and audit once" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.block_kill(self())
    tmux_session = lease.tmux_session

    first_task = Task.async(fn -> TerminalSessions.delete(lease.id, tmux: Tmux) end)
    assert_receive {:kill_started, first_pid, ^tmux_session, "deleting"}

    second_task = Task.async(fn -> TerminalSessions.delete(lease.id, tmux: Tmux) end)
    assert Task.yield(second_task, 100) == nil

    send(first_pid, :continue_kill)
    assert {:ok, first} = Task.await(first_task, 5_000)
    assert {:ok, second} = Task.await(second_task, 5_000)
    assert first.state == "deleted"
    assert second.state == "deleted"
    assert Tmux.kills() == [tmux_session]

    deleted_events =
      Casein.Audit.list(limit: 20)
      |> Enum.count(&(&1.target_ref == lease.id and &1.action == "mobile.terminal_deleted"))

    assert deleted_events == 1
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

  test "pane replacement during exact owner cutoff is revalidated before kill" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    TerminalControl.block_stop(self())
    tmux_session = lease.tmux_session
    sid = lease.sid

    task =
      Task.async(fn ->
        TerminalSessions.delete(lease.id, tmux: Tmux, terminal_control: TerminalControl)
      end)

    assert_receive {:exact_stop_started, stop_pid, "workspace", ^sid}
    Tmux.replace_pane(tmux_session, "%replacement", lease.pane_role)
    send(stop_pid, :continue_exact_stop)

    assert {:error, :pane_identity_mismatch} = Task.await(task, 5_000)
    assert Repo.get!(TerminalSession, lease.id).state == "deleting"
    assert Tmux.session_exists?(tmux_session)
    assert Tmux.kills() == []
  end

  test "active same-name replacement at atomic kill boundary is preserved" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.replace_on_kill()

    assert {:error, :mobile_terminal_identity_mismatch} =
             TerminalSessions.delete(lease.id, tmux: Tmux)

    assert Repo.get!(TerminalSession, lease.id).state == "deleting"
    assert Tmux.session_exists?(lease.tmux_session)
    assert Tmux.kills() == []
  end

  test "reaper completes a deleting lease whose exact tmux target is already absent" do
    now = ~U[2026-08-05 10:00:00Z]
    first_attrs = attrs()

    assert {:ok, lease} =
             TerminalSessions.create(first_attrs, tmux: Tmux, now: now, ttl_seconds: 60)

    assert {:ok, sibling} =
             TerminalSessions.create(%{first_attrs | request_id: Ecto.UUID.generate()},
               tmux: Tmux,
               now: now,
               ttl_seconds: 60
             )

    lease
    |> TerminalSession.transition_changeset(%{state: "deleting"})
    |> Repo.update!()

    Tmux.external_remove(lease.tmux_session)

    assert [{:ok, deleted}] =
             TerminalSessions.reconcile_due(tmux: Tmux, now: DateTime.add(now, 1, :second))

    assert deleted.state == "deleted"
    assert Tmux.session_exists?(sibling.tmux_session)
    assert Tmux.kills() == []
  end

  test "teardown treats disappearance between exists and topology reads as absent" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.disappear_on_next_list()

    assert {:ok, deleted} = TerminalSessions.delete(lease.id, tmux: Tmux)
    assert deleted.state == "deleted"
    refute Tmux.session_exists?(lease.tmux_session)
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

  test "delete sanitizes secret-bearing adapter errors from return, logs, and audit" do
    assert {:ok, lease} = TerminalSessions.create(attrs(), tmux: Tmux)
    secret = "delete adapter credential-like output"
    Tmux.kill_error({:subprocess_failed, secret})

    log =
      capture_log(fn ->
        assert {:error, :tmux_teardown_failed} =
                 TerminalSessions.delete(lease.id, tmux: Tmux)
      end)

    refute log =~ secret
    refute inspect(Casein.Audit.list(limit: 20)) =~ secret
    assert Repo.get!(TerminalSession, lease.id).state == "deleting"
  end

  test "ordinary reconcile return sanitizes secret-bearing adapter errors" do
    now = ~U[2026-08-05 10:00:00Z]

    assert {:ok, lease} =
             TerminalSessions.create(attrs(), tmux: Tmux, now: now, ttl_seconds: 60)

    secret = "reaper adapter token-like output"
    Tmux.kill_error({:subprocess_failed, secret})

    log =
      capture_log(fn ->
        assert [{:error, :tmux_teardown_failed}] =
                 Casein.Mobile.TerminalReaper.safe_reconcile(fn ->
                   TerminalSessions.reconcile_due(
                     tmux: Tmux,
                     now: DateTime.add(now, 61, :second)
                   )
                 end)
      end)

    refute log =~ secret
    refute inspect(Casein.Audit.list(limit: 20)) =~ secret
    assert Repo.get!(TerminalSession, lease.id).state == "deleting"
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
    assert pending.failure_code == "tmux_temporarily_unavailable"

    Tmux.ensure_error(nil)
    assert [{:ok, active}] = TerminalSessions.reconcile_startup(tmux: Tmux)
    assert active.id == pending.id
    assert active.state == "active"
    assert Repo.aggregate(TerminalSession, :count) == 1
  end

  test "fatal never-active topologies are reaped by exact authoritative name only" do
    Enum.each([:empty, :missing_id, :multiple], fn topology ->
      Tmux.provision_topology(topology)
      request = %{attrs() | request_id: Ecto.UUID.generate()}

      expected =
        case topology do
          :empty -> :missing_initial_pane
          :missing_id -> :missing_pane_id
          :multiple -> :unexpected_topology
        end

      assert {:error, ^expected} = TerminalSessions.create(request, tmux: Tmux)
      lease = Repo.get_by!(TerminalSession, request_id: request.request_id)
      assert lease.state == "deleted"
      refute Tmux.session_exists?(lease.tmux_session)
      assert lease.tmux_session in Tmux.kills()

      rejected =
        Casein.Audit.list(limit: 50)
        |> Enum.find(&(&1.target_ref == lease.id and &1.action == "mobile.terminal_rejected"))

      assert rejected.metadata.reason_code == Atom.to_string(expected)
    end)
  end

  test "never-active cleanup leaves sibling mobile terminals untouched" do
    assert {:ok, sibling} = TerminalSessions.create(attrs(), tmux: Tmux)
    Tmux.provision_topology(:multiple)
    request = %{attrs() | request_id: Ecto.UUID.generate()}

    assert {:error, :unexpected_topology} = TerminalSessions.create(request, tmux: Tmux)
    failed = Repo.get_by!(TerminalSession, request_id: request.request_id)

    assert failed.state == "deleted"
    assert Tmux.session_exists?(sibling.tmux_session)
    refute sibling.tmux_session in Tmux.kills()
  end

  test "never-active same-name replacement at atomic kill boundary is preserved" do
    Tmux.provision_topology(:multiple)
    Tmux.replace_on_kill()

    assert {:error, :unexpected_topology} = TerminalSessions.create(attrs(), tmux: Tmux)
    [lease] = Repo.all(TerminalSession)

    assert lease.state == "deleting"
    assert Tmux.session_exists?(lease.tmux_session)
    assert Tmux.kills() == []
  end

  test "durable provisioning failures use fixed allowlisted codes, never inspected output" do
    secret = "raw tmux pane output / credential-like material"
    Tmux.ensure_error({:subprocess_failed, secret})

    assert {:error, :tmux_provision_failed} = TerminalSessions.create(attrs(), tmux: Tmux)

    [pending] = Repo.all(TerminalSession)
    assert pending.failure_code == "tmux_provision_failed"
    refute pending.failure_code =~ secret

    audit = Casein.Audit.list(limit: 20) |> Enum.filter(&(&1.target_ref == pending.id))
    assert audit == []
    refute inspect(Casein.Audit.list(limit: 20)) =~ secret
  end

  test "reaper logs and returns only allowlisted codes for exceptions and exits" do
    exception_secret = "exception secret material"

    exception_log =
      capture_log(fn ->
        assert {:error, :reconcile_failed} =
                 Casein.Mobile.TerminalReaper.safe_reconcile(fn ->
                   raise exception_secret
                 end)
      end)

    assert exception_log =~ "reason_code=reconcile_failed"
    refute exception_log =~ exception_secret

    exit_secret = "exit secret material"

    exit_log =
      capture_log(fn ->
        assert {:error, :reconcile_exited} =
                 Casein.Mobile.TerminalReaper.safe_reconcile(fn ->
                   exit({:adapter_failed, exit_secret})
                 end)
      end)

    assert exit_log =~ "reason_code=reconcile_exited"
    refute exit_log =~ exit_secret
  end

  test "ordinary mob-prefixed sessions archive unless explicitly disposable" do
    ordinary_tmux = "casein_workspace_mob-client-chosen"
    ephemeral_tmux = "casein_workspace_server-owned"
    Casein.Terminals.ScrollbackArchive.delete(ordinary_tmux)
    Casein.Terminals.ScrollbackArchive.delete(ephemeral_tmux)

    on_exit(fn ->
      Casein.Terminals.ScrollbackArchive.delete(ordinary_tmux)
      Casein.Terminals.ScrollbackArchive.delete(ephemeral_tmux)
    end)

    assert :ok =
             Casein.Terminals.Session.terminate(:normal, %{
               tmux: ordinary_tmux,
               sid: "mob-client-chosen",
               buffer: "ordinary output",
               disposable?: false
             })

    assert Casein.Terminals.ScrollbackArchive.present?(ordinary_tmux)

    assert :ok =
             Casein.Terminals.Session.terminate(:normal, %{
               tmux: ephemeral_tmux,
               sid: "not-prefixed",
               buffer: "must not persist",
               disposable?: true
             })

    refute Casein.Terminals.ScrollbackArchive.present?(ephemeral_tmux)
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
