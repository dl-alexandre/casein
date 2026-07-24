defmodule Casein.FilePanesOffloadTest do
  @moduledoc """
  I/O offload regression tests for FilePanes: per-pane queues, shape-correct
  rehydrate crash replies, clear/0 waiter release, window_index consistency,
  and session_terminated batch close.
  """
  use Casein.DataCase, async: false

  alias Casein.FilePanes
  alias Casein.FilePanes.FilePaneRegistration
  alias Casein.Repo
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_persistence = Application.get_env(:casein, :file_pane_persistence)
    prev_io_delay = Application.get_env(:casein, :file_panes_test_io_delay_ms)
    prev_rehydrate_delay = Application.get_env(:casein, :file_panes_test_rehydrate_delay_ms)

    Application.put_env(:casein, :tmux_adapter, FakeAdapter)
    Application.put_env(:casein, :file_pane_persistence, true)
    Application.delete_env(:casein, :file_panes_test_io_delay_ms)
    Application.delete_env(:casein, :file_panes_test_rehydrate_delay_ms)
    FilePanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)

    on_exit(fn ->
      FilePanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspaces_root, prev_root)
      restore(:file_pane_persistence, prev_persistence)

      if prev_io_delay,
        do: Application.put_env(:casein, :file_panes_test_io_delay_ms, prev_io_delay),
        else: Application.delete_env(:casein, :file_panes_test_io_delay_ms)

      if prev_rehydrate_delay,
        do:
          Application.put_env(:casein, :file_panes_test_rehydrate_delay_ms, prev_rehydrate_delay),
        else: Application.delete_env(:casein, :file_panes_test_rehydrate_delay_ms)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        20 -> wait_until(fun, attempts - 1)
      end
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not met before timeout")

  defp seed_workspace! do
    root =
      Path.join(System.tmp_dir!(), "file-panes-offload-#{System.unique_integer([:positive])}")

    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:casein, :workspaces_root, root)
    {:ok, workspace} = Casein.Workspaces.attach_folder(path)
    {path, workspace}
  end

  defp seed_session!(session, pane_id, window_id \\ "@1") do
    windows = FakeState.get(:fake_tmux_windows, %{})
    panes = FakeState.get(:fake_tmux_panes, %{})

    existing_windows = Map.get(windows, session, [])
    existing_panes = Map.get(panes, session, [])

    window_entry = %{
      id: window_id,
      index: length(existing_windows),
      name: "bash",
      active: existing_windows == [],
      panes: 1,
      activity: 0
    }

    pane_entry = %{
      id: pane_id,
      window_id: window_id,
      index: length(existing_panes),
      active: existing_panes == [],
      left: 0,
      top: 0,
      width: 120,
      height: 40,
      current_command: "casein-file-pane",
      current_path: "/tmp"
    }

    windows =
      Map.put(
        windows,
        session,
        Enum.uniq_by(existing_windows ++ [window_entry], & &1.id)
      )

    panes =
      Map.put(
        panes,
        session,
        Enum.uniq_by(existing_panes ++ [pane_entry], & &1.id)
      )

    FakeState.put(:fake_tmux_windows, windows)
    FakeState.put(:fake_tmux_panes, panes)
  end

  defp register_pane!(workspace, session, pane_id, path \\ "lib/a.ex") do
    assert {:ok, registration} =
             FilePanes.register(%{
               pane_id: pane_id,
               workspace_id: workspace.id,
               tmux_session: session,
               pane_window_id: "@1",
               placement: "right",
               anchor_pane_id: "%1",
               anchor_window_id: "@1",
               open_files: [%{path: path, line: 1}],
               active_path: path
             })

    registration
  end

  test "mailbox stays responsive while a slow register is in flight" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_offload_responsive"
    warm_pane = "%warm"
    slow_pane = "%slow"
    seed_session!(session, warm_pane)
    seed_session!(session, slow_pane)

    warm = register_pane!(workspace, session, warm_pane, "warm.ex")

    Application.put_env(:casein, :file_panes_test_io_delay_ms, 400)
    parent = self()

    spawn(fn ->
      send(parent, {:reg_started, self()})

      result =
        FilePanes.register(%{
          pane_id: slow_pane,
          workspace_id: workspace.id,
          tmux_session: session,
          pane_window_id: "@2",
          open_files: [%{path: "slow.ex", line: nil}],
          active_path: "slow.ex"
        })

      send(parent, {:reg_done, result})
    end)

    assert_receive {:reg_started, _}, 1_000

    wait_until(fn ->
      state = :sys.get_state(FilePanes)
      Map.has_key?(state.inflight_panes, slow_pane)
    end)

    t0 = System.monotonic_time(:millisecond)
    assert FilePanes.get_by_pane(warm_pane).pane_id == warm_pane
    listed = FilePanes.list_for_workspace(warm.workspace_id)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert Enum.any?(listed, &(&1.pane_id == warm_pane))

    assert elapsed < 100,
           "expected warm get/list to complete while register is in flight, took #{elapsed}ms"

    assert_receive {:reg_done, {:ok, _}}, 5_000
  end

  test "concurrent registers for one pane_id serialize via the per-pane queue" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_offload_collapse"
    pane_id = "%collapse"
    seed_session!(session, pane_id)

    Application.put_env(:casein, :file_panes_test_io_delay_ms, 200)
    parent = self()

    spawn(fn ->
      result =
        FilePanes.register(%{
          pane_id: pane_id,
          workspace_id: workspace.id,
          tmux_session: session,
          pane_window_id: "@1",
          open_files: [%{path: "first.ex", line: nil}],
          active_path: "first.ex"
        })

      send(parent, {:first, result})
    end)

    spawn(fn ->
      receive do
      after
        30 -> :ok
      end

      result =
        FilePanes.register(%{
          pane_id: pane_id,
          workspace_id: workspace.id,
          tmux_session: session,
          pane_window_id: "@1",
          open_files: [%{path: "second.ex", line: nil}],
          active_path: "second.ex"
        })

      send(parent, {:second, result})
    end)

    assert_receive {:first, {:ok, first}}, 5_000
    assert_receive {:second, {:ok, second}}, 5_000

    assert first.pane_id == pane_id
    assert second.pane_id == pane_id
    assert second.active_path == "second.ex"

    final = FilePanes.get_by_pane(pane_id)
    assert final.active_path == "second.ex"

    open_rows =
      from(r in FilePaneRegistration, where: r.pane_id == ^pane_id and r.status == :open)
      |> Repo.all()

    assert length(open_rows) == 1
    assert hd(open_rows).active_path == "second.ex"
  end

  test "re-register after deregister queues behind deregister and ends open" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_offload_order"
    pane_id = "%order"
    seed_session!(session, pane_id)
    _registration = register_pane!(workspace, session, pane_id)

    Application.put_env(:casein, :file_panes_test_io_delay_ms, 200)
    parent = self()

    spawn(fn ->
      send(parent, {:dereg_started, self()})
      result = FilePanes.deregister(pane_id)
      send(parent, {:dereg_done, result})
    end)

    assert_receive {:dereg_started, _}, 1_000

    wait_until(fn ->
      state = :sys.get_state(FilePanes)

      Map.has_key?(state.inflight_panes, pane_id) or
        match?({:value, _}, :queue.peek(Map.get(state.op_queue, pane_id, :queue.new())))
    end)

    spawn(fn ->
      result =
        FilePanes.register(%{
          pane_id: pane_id,
          workspace_id: workspace.id,
          tmux_session: session,
          pane_window_id: "@1",
          open_files: [%{path: "after.ex", line: nil}],
          active_path: "after.ex"
        })

      send(parent, {:rereg_done, result})
    end)

    assert_receive {:dereg_done, :ok}, 5_000
    assert_receive {:rereg_done, {:ok, reg}}, 5_000

    assert reg.pane_id == pane_id
    assert reg.active_path == "after.ex"
    assert FilePanes.get_by_pane(pane_id).active_path == "after.ex"

    assert %FilePaneRegistration{status: :open, active_path: "after.ex"} =
             Repo.get_by(FilePaneRegistration, pane_id: pane_id, status: :open)
  end

  test "workspace_index and window_index stay consistent after interleaved ops" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_offload_invariant"
    panes = ["%i1", "%i2", "%i3"]

    for {pane_id, idx} <- Enum.with_index(panes, 1) do
      FakeState.put(:fake_tmux_windows, %{
        session => [
          %{
            id: "@#{idx}",
            index: idx - 1,
            name: "w#{idx}",
            active: idx == 1,
            panes: 1,
            activity: 0
          }
        ]
      })

      seed_session!(session, pane_id)
    end

    # Give each pane a distinct window so they don't displace each other.
    parent = self()

    tasks =
      for {pane_id, idx} <- Enum.with_index(panes, 1),
          action <- [:register, :deregister, :register] do
        spawn(fn ->
          result =
            case action do
              :register ->
                FilePanes.register(%{
                  pane_id: pane_id,
                  workspace_id: workspace.id,
                  tmux_session: session,
                  pane_window_id: "@#{idx}",
                  open_files: [%{path: "#{pane_id}.ex", line: nil}],
                  active_path: "#{pane_id}.ex"
                })

              :deregister ->
                FilePanes.deregister(pane_id)
            end

          send(parent, {:op_done, pane_id, action, result})
        end)
      end

    for _ <- tasks do
      assert_receive {:op_done, _pane, _action, _result}, 10_000
    end

    state = :sys.get_state(FilePanes)

    indexed =
      state.workspace_index
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

    for pane_id <- indexed do
      assert is_map(FilePanes.get_by_pane(pane_id)),
             "workspace_index references missing ETS pane #{pane_id}"
    end

    ets_panes =
      :ets.tab2list(:casein_file_panes)
      |> Enum.map(fn {pane_id, _} -> pane_id end)
      |> Enum.sort()

    for pane_id <- ets_panes do
      assert pane_id in indexed, "ETS pane #{pane_id} missing from workspace_index"
    end

    # window_index must point at live ETS panes only.
    for {{_session, _window}, pane_id} <- state.window_index do
      assert pane_id in ets_panes, "window_index pane #{pane_id} missing from ETS"
      assert is_map(lookup = FilePanes.get_by_pane(pane_id))
      assert lookup.pane_id == pane_id
    end
  end

  test "killed offload task replies file_op_crashed and drains the pane queue" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_offload_crash"
    pane_id = "%crash"
    seed_session!(session, pane_id)

    Application.put_env(:casein, :file_panes_test_io_delay_ms, 500)
    parent = self()

    spawn(fn ->
      send(parent, {:reg_started, self()})

      result =
        FilePanes.register(%{
          pane_id: pane_id,
          workspace_id: workspace.id,
          tmux_session: session,
          pane_window_id: "@1",
          open_files: [%{path: "crash.ex", line: nil}],
          active_path: "crash.ex"
        })

      send(parent, {:reg_done, result})
    end)

    assert_receive {:reg_started, _}, 1_000

    wait_until(fn ->
      state = :sys.get_state(FilePanes)
      Map.has_key?(state.inflight_panes, pane_id)
    end)

    spawn(fn ->
      result =
        FilePanes.register(%{
          pane_id: pane_id,
          workspace_id: workspace.id,
          tmux_session: session,
          pane_window_id: "@1",
          open_files: [%{path: "survivor.ex", line: nil}],
          active_path: "survivor.ex"
        })

      send(parent, {:second_done, result})
    end)

    wait_until(fn ->
      state = :sys.get_state(FilePanes)
      q = Map.get(state.op_queue, pane_id, :queue.new())
      not :queue.is_empty(q)
    end)

    state = :sys.get_state(FilePanes)
    task_pid = state.pending_ops |> Map.values() |> hd() |> Map.fetch!(:pid)
    Process.exit(task_pid, :kill)

    assert_receive {:reg_done, {:error, :file_op_crashed}}, 5_000
    assert_receive {:second_done, {:ok, survivor}}, 5_000
    assert survivor.active_path == "survivor.ex"
    assert FilePanes.get_by_pane(pane_id).active_path == "survivor.ex"
  end

  test "crashed rehydrate op replies shape-correct nil, not an error tuple" do
    pane_id = "%rehydrate-crash-#{System.unique_integer([:positive])}"

    Application.put_env(:casein, :file_panes_test_rehydrate_delay_ms, 500)
    on_exit(fn -> Application.delete_env(:casein, :file_panes_test_rehydrate_delay_ms) end)

    parent = self()

    spawn(fn ->
      send(parent, {:lookup_started, self()})
      send(parent, {:lookup_result, FilePanes.get_by_pane(pane_id)})
    end)

    assert_receive {:lookup_started, _}, 1_000

    wait_until(fn ->
      state = :sys.get_state(FilePanes)

      case Enum.find(state.pending_ops, fn {_ref, op} -> op.kind == :rehydrate end) do
        {_ref, op} ->
          Process.exit(op.pid, :kill)
          true

        _ ->
          false
      end
    end)

    # Callers pattern-match `registration | nil` — an error tuple would crash them.
    assert_receive {:lookup_result, nil}, 2_000
  end

  test "flush waits for an acknowledged tab mutation to persist" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_flush"
    pane_id = "%flush"
    seed_session!(session, pane_id)

    assert {:ok, _} =
             FilePanes.register(%{
               pane_id: pane_id,
               workspace_id: workspace.id,
               tmux_session: session,
               pane_window_id: "@1",
               open_files: [%{path: "first.ex", line: nil}],
               active_path: "first.ex"
             })

    Application.put_env(:casein, :file_panes_test_io_delay_ms, 300)
    assert {:ok, _} = FilePanes.open_tab(pane_id, "second.ex")

    parent = self()
    spawn(fn -> send(parent, {:flush_result, FilePanes.flush()}) end)

    wait_until(fn -> :sys.get_state(FilePanes).flush_waiters != [] end)
    assert_receive {:flush_result, :ok}, 2_000

    persisted = Repo.get_by!(FilePaneRegistration, pane_id: pane_id)
    assert Enum.any?(persisted.open_files, &(&1["path"] == "second.ex"))
  end

  test "clear replies file_cleared to queued (not yet started) op waiters" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_clear_queue"
    pane_id = "%clearq"
    seed_session!(session, pane_id)

    Application.put_env(:casein, :file_panes_test_io_delay_ms, 500)
    parent = self()

    spawn(fn ->
      FilePanes.register(%{
        pane_id: pane_id,
        workspace_id: workspace.id,
        tmux_session: session,
        pane_window_id: "@1",
        open_files: [%{path: "slow.ex", line: nil}],
        active_path: "slow.ex"
      })
    end)

    wait_until(fn ->
      state = :sys.get_state(FilePanes)
      Map.has_key?(state.inflight_panes, pane_id)
    end)

    spawn(fn ->
      result =
        FilePanes.register(%{
          pane_id: pane_id,
          workspace_id: workspace.id,
          tmux_session: session,
          pane_window_id: "@1",
          open_files: [%{path: "queued.ex", line: nil}],
          active_path: "queued.ex"
        })

      send(parent, {:queued_result, result})
    end)

    wait_until(fn ->
      state = :sys.get_state(FilePanes)
      Map.has_key?(state.op_queue, pane_id)
    end)

    :ok = FilePanes.clear()

    assert_receive {:queued_result, {:error, :file_cleared}}, 2_000
  end

  test "session_terminated batch-closes persisted rows and drops ETS entries" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_session_term"
    panes = [{"%t1", "@1"}, {"%t2", "@2"}]

    for {pane_id, window_id} <- panes do
      seed_session!(session, pane_id, window_id)

      assert {:ok, _} =
               FilePanes.register(%{
                 pane_id: pane_id,
                 workspace_id: workspace.id,
                 tmux_session: session,
                 pane_window_id: window_id,
                 open_files: [%{path: "#{pane_id}.ex", line: nil}],
                 active_path: "#{pane_id}.ex"
               })
    end

    for {pane_id, _} <- panes do
      assert Repo.get_by(FilePaneRegistration, pane_id: pane_id, status: :open)
      assert FilePanes.get_by_pane(pane_id)
    end

    send(FilePanes, {Casein.Terminals.TmuxTopology, {:session_terminated, %{session: session}}})

    wait_until(fn ->
      Enum.all?(panes, fn {pane_id, _} ->
        is_nil(FilePanes.get_by_pane(pane_id)) and
          is_nil(Repo.get_by(FilePaneRegistration, pane_id: pane_id, status: :open))
      end)
    end)

    state = :sys.get_state(FilePanes)
    assert state.workspace_index[workspace.id] in [nil, []]

    assert state.window_index == %{} or
             not Enum.any?(state.window_index, fn {{s, _}, _} -> s == session end)
  end

  test "rehydrate keeps the GenServer responsive (delay is in the offload task)" do
    {_path, workspace} = seed_workspace!()
    session = "devide_ws_fp_rehydrate_offload"
    pane_id = "%rehydrate-off"
    seed_session!(session, pane_id)

    FilePanes.clear()

    {:ok, _} =
      %FilePaneRegistration{}
      |> FilePaneRegistration.changeset(%{
        workspace_id: workspace.id,
        tmux_session: session,
        pane_id: pane_id,
        pane_window_id: "@1",
        open_files: [%{"path" => "cold.ex", "line" => nil}],
        active_path: "cold.ex",
        status: :open
      })
      |> Repo.insert()

    Application.put_env(:casein, :file_panes_test_rehydrate_delay_ms, 200)
    parent = self()
    panes_pid = Process.whereis(FilePanes)

    spawn(fn ->
      send(parent, {:lookup_result, FilePanes.get_by_pane(pane_id)})
    end)

    wait_until(fn ->
      state = :sys.get_state(FilePanes)
      Enum.any?(state.pending_ops, fn {_ref, op} -> op.kind == :rehydrate end)
    end)

    # While rehydrate is in flight, the GenServer must stay responsive — the
    # artificial delay lives in the task, not the singleton mailbox.
    t0 = System.monotonic_time(:millisecond)
    state = :sys.get_state(FilePanes)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert is_map(state.pending_ops)
    assert elapsed < 100, "server blocked during rehydrate for #{elapsed}ms"
    assert Process.alive?(panes_pid)

    assert_receive {:lookup_result, %{pane_id: ^pane_id, active_path: "cold.ex"}}, 5_000
  end
end
