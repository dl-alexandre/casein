defmodule DevIDE.PreviewPanesOffloadTest do
  @moduledoc """
  Slice 1 regression tests: I/O offload, $callers ownership, per-pane queues,
  and the get_by_session self-call guard.
  """
  use DevIDE.DataCase, async: false

  alias DevIDE.PreviewPanes
  alias DevIDE.PreviewPanes.PreviewPaneRegistration
  alias DevIDE.Repo
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_persistence = Application.get_env(:dev_ide, :preview_pane_persistence_enabled)
    prev_delay = Application.get_env(:dev_ide, :preview_panes_test_browser_delay_ms)

    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    Application.put_env(:dev_ide, :preview_pane_persistence_enabled, true)
    Application.delete_env(:dev_ide, :preview_panes_test_browser_delay_ms)
    PreviewPanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)

    on_exit(fn ->
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspaces_root, prev_root)
      restore(:preview_pane_persistence_enabled, prev_persistence)

      if prev_delay,
        do: Application.put_env(:dev_ide, :preview_panes_test_browser_delay_ms, prev_delay),
        else: Application.delete_env(:dev_ide, :preview_panes_test_browser_delay_ms)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

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
      Path.join(System.tmp_dir!(), "preview-panes-offload-#{System.unique_integer([:positive])}")

    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    {root, path}
  end

  defp seed_session!(session, pane_id) do
    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "devide-preview",
          current_path: "/tmp"
        }
      ]
    })
  end

  defp register_pane!(session, pane_id, path, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          "pane_id" => pane_id,
          "url" => "http://localhost:5173/",
          "cwd" => path,
          "tmux_session" => session
        },
        extra
      )

    assert {:ok, registration} = PreviewPanes.register(attrs)
    registration
  end

  test "mailbox stays responsive while a slow register is in flight" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_offload_responsive"
    warm_pane = "%warm"
    slow_pane = "%slow"
    seed_session!(session, warm_pane)
    seed_session!(session, slow_pane)

    warm = register_pane!(session, warm_pane, path)

    Application.put_env(:dev_ide, :preview_panes_test_browser_delay_ms, 400)
    parent = self()

    spawn(fn ->
      send(parent, {:reg_started, self()})

      result =
        PreviewPanes.register(%{
          "pane_id" => slow_pane,
          "url" => "http://localhost:5173/slow",
          "cwd" => path,
          "tmux_session" => session
        })

      send(parent, {:reg_done, result})
    end)

    assert_receive {:reg_started, _}, 1_000

    wait_until(fn ->
      state = :sys.get_state(PreviewPanes)
      Map.has_key?(state.inflight_panes, slow_pane)
    end)

    t0 = System.monotonic_time(:millisecond)
    assert PreviewPanes.get_by_pane(warm_pane).pane_id == warm_pane
    listed = PreviewPanes.list_for_workspace(warm.workspace_id)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert Enum.any?(listed, &(&1.pane_id == warm_pane))

    assert elapsed < 100,
           "expected warm get/list to complete while register is in flight, took #{elapsed}ms"

    assert_receive {:reg_done, {:ok, _}}, 5_000
  end

  test "concurrent registers for one pane_id serialize via the per-pane queue" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_offload_collapse"
    pane_id = "%collapse"
    seed_session!(session, pane_id)

    Application.put_env(:dev_ide, :preview_panes_test_browser_delay_ms, 200)
    parent = self()

    spawn(fn ->
      result =
        PreviewPanes.register(%{
          "pane_id" => pane_id,
          "url" => "http://localhost:5173/first",
          "cwd" => path,
          "tmux_session" => session
        })

      send(parent, {:first, result})
    end)

    spawn(fn ->
      # Let the first register mark the pane in-flight before we enqueue.
      receive do
      after
        30 -> :ok
      end

      result =
        PreviewPanes.register(%{
          "pane_id" => pane_id,
          "url" => "http://localhost:5173/second",
          "cwd" => path,
          "tmux_session" => session
        })

      send(parent, {:second, result})
    end)

    assert_receive {:first, {:ok, first}}, 5_000
    assert_receive {:second, {:ok, second}}, 5_000

    assert first.pane_id == pane_id
    assert second.pane_id == pane_id
    assert second.url == "http://localhost:5173/second"

    final = PreviewPanes.get_by_pane(pane_id)
    assert final.url == "http://localhost:5173/second"

    open_rows =
      from(r in PreviewPaneRegistration, where: r.pane_id == ^pane_id and r.status == :open)
      |> Repo.all()

    assert length(open_rows) == 1
    assert hd(open_rows).url == "http://localhost:5173/second"
  end

  test "re-register after deregister queues behind deregister and ends open" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_offload_order"
    pane_id = "%order"
    seed_session!(session, pane_id)
    _registration = register_pane!(session, pane_id, path)

    Application.put_env(:dev_ide, :preview_panes_test_browser_delay_ms, 200)
    parent = self()

    spawn(fn ->
      send(parent, {:dereg_started, self()})
      result = PreviewPanes.deregister(pane_id)
      send(parent, {:dereg_done, result})
    end)

    assert_receive {:dereg_started, _}, 1_000

    wait_until(fn ->
      state = :sys.get_state(PreviewPanes)

      Map.has_key?(state.inflight_panes, pane_id) or
        match?({:value, _}, :queue.peek(Map.get(state.op_queue, pane_id, :queue.new())))
    end)

    spawn(fn ->
      result =
        PreviewPanes.register(%{
          "pane_id" => pane_id,
          "url" => "http://localhost:5173/after-dereg",
          "cwd" => path,
          "tmux_session" => session
        })

      send(parent, {:rereg_done, result})
    end)

    assert_receive {:dereg_done, :ok}, 5_000
    assert_receive {:rereg_done, {:ok, reg}}, 5_000

    assert reg.pane_id == pane_id
    assert reg.url == "http://localhost:5173/after-dereg"
    assert PreviewPanes.get_by_pane(pane_id).url == "http://localhost:5173/after-dereg"

    assert %PreviewPaneRegistration{status: :open, url: "http://localhost:5173/after-dereg"} =
             Repo.get_by(PreviewPaneRegistration, pane_id: pane_id, status: :open)
  end

  test "workspace_index stays consistent with ETS after interleaved lifecycle ops" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_offload_invariant"
    panes = ["%i1", "%i2", "%i3"]

    for pane_id <- panes do
      seed_session!(session, pane_id)
    end

    parent = self()

    tasks =
      for pane_id <- panes, action <- [:register, :deregister, :register] do
        spawn(fn ->
          result =
            case action do
              :register ->
                PreviewPanes.register(%{
                  "pane_id" => pane_id,
                  "url" => "http://localhost:5173/#{pane_id}",
                  "cwd" => path,
                  "tmux_session" => session
                })

              :deregister ->
                PreviewPanes.deregister(pane_id)
            end

          send(parent, {:op_done, pane_id, action, result})
        end)
      end

    for _ <- tasks do
      assert_receive {:op_done, _pane, _action, _result}, 10_000
    end

    state = :sys.get_state(PreviewPanes)

    indexed =
      state.workspace_index
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

    for pane_id <- indexed do
      assert is_map(PreviewPanes.get_by_pane(pane_id)),
             "workspace_index references missing ETS pane #{pane_id}"
    end

    ets_panes =
      :ets.tab2list(:dev_ide_preview_panes)
      |> Enum.map(fn {pane_id, _} -> pane_id end)
      |> Enum.sort()

    # Every ETS row must appear in some workspace_index entry.
    for pane_id <- ets_panes do
      assert pane_id in indexed, "ETS pane #{pane_id} missing from workspace_index"
    end
  end

  test "killed offload task replies preview_op_crashed and drains the pane queue" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_offload_crash"
    pane_id = "%crash"
    seed_session!(session, pane_id)

    Application.put_env(:dev_ide, :preview_panes_test_browser_delay_ms, 500)
    parent = self()

    spawn(fn ->
      send(parent, {:reg_started, self()})

      result =
        PreviewPanes.register(%{
          "pane_id" => pane_id,
          "url" => "http://localhost:5173/crash",
          "cwd" => path,
          "tmux_session" => session
        })

      send(parent, {:reg_done, result})
    end)

    assert_receive {:reg_started, _}, 1_000

    wait_until(fn ->
      state = :sys.get_state(PreviewPanes)
      Map.has_key?(state.inflight_panes, pane_id)
    end)

    # Queue a second register behind the doomed one.
    spawn(fn ->
      result =
        PreviewPanes.register(%{
          "pane_id" => pane_id,
          "url" => "http://localhost:5173/survivor",
          "cwd" => path,
          "tmux_session" => session
        })

      send(parent, {:second_done, result})
    end)

    wait_until(fn ->
      state = :sys.get_state(PreviewPanes)
      q = Map.get(state.op_queue, pane_id, :queue.new())
      not :queue.is_empty(q)
    end)

    state = :sys.get_state(PreviewPanes)
    task_pid = state.pending_ops |> Map.values() |> hd() |> Map.fetch!(:pid)
    Process.exit(task_pid, :kill)

    assert_receive {:reg_done, {:error, :preview_op_crashed}}, 5_000
    assert_receive {:second_done, {:ok, survivor}}, 5_000
    assert survivor.url == "http://localhost:5173/survivor"
    assert PreviewPanes.get_by_pane(pane_id).url == "http://localhost:5173/survivor"
  end

  test "get_by_session self-call guard returns nil without deadlocking" do
    parent = self()
    ref = make_ref()

    # :sys.replace_state evaluates Fun inside the PreviewPanes process — the
    # exact re-entrancy hazard Control.record_control_activity used to hit.
    :sys.replace_state(PreviewPanes, fn state ->
      result = PreviewPanes.get_by_session(-1)
      send(parent, {ref, result})
      state
    end)

    assert_receive {^ref, nil}, 1_000
  end

  test "get_by_session is ETS-first when a registration is warm" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_offload_session_ets"
    pane_id = "%sess"
    seed_session!(session, pane_id)
    registration = register_pane!(session, pane_id, path)

    # Warm path must not require a GenServer round-trip that could re-enter.
    assert PreviewPanes.get_by_session(registration.control_session_id).pane_id == pane_id
  end
end

defmodule DevIDE.PreviewPanesOwnershipTest do
  @moduledoc """
  Cascade-class death proof: register's manager HTTP must resolve a privately
  owned Req.Test stub via $callers with NO PreviewPanes singleton allowance.
  """
  use DevIDE.DataCase, async: true

  alias DevIDE.Integrations.Manager.Client
  alias DevIDE.PreviewPanes
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)

    on_exit(fn ->
      if prev_tmux,
        do: Application.put_env(:dev_ide, :tmux_adapter, prev_tmux),
        else: Application.delete_env(:dev_ide, :tmux_adapter)
    end)

    :ok
  end

  test "register hits a private Req.Test stub without allowing PreviewPanes pid" do
    parent = self()
    uid = System.unique_integer([:positive])
    workspace_id = "ws-owner-#{uid}"
    pane_id = "%own-#{uid}"
    session = "devide_ws_owner_#{uid}"
    workspace_path = Path.join(System.tmp_dir!(), "owner-ws-#{uid}")
    File.mkdir_p!(workspace_path)

    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "devide-preview",
          current_path: workspace_path
        }
      ]
    })

    # Private stub owned by this test process. Intentionally no
    # Req.Test.allow(..., Process.whereis(DevIDE.PreviewPanes)) — that is the
    # cascade-class footgun Slice 1 deletes from manager_req_test.ex.
    panes_pid = Process.whereis(DevIDE.PreviewPanes)
    assert is_pid(panes_pid)

    Req.Test.stub(Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", ^workspace_id, "status"]} = conn ->
        send(parent, {:manager_status_hit, workspace_id})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => workspace_id,
            "name" => "owner-#{uid}",
            "user" => "dev",
            "status" => "running",
            "type" => "v3",
            "branch" => "main",
            "path" => workspace_path
          })
        )

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "workspace_id" => workspace_id,
               "tmux_session" => session
             })

    assert_receive {:manager_status_hit, ^workspace_id}, 5_000
    assert registration.pane_id == pane_id
    assert registration.workspace_id == workspace_id
    assert PreviewPanes.get_by_pane(pane_id).workspace_id == workspace_id

    _ = PreviewPanes.deregister(pane_id)
  end
end
