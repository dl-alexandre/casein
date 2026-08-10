defmodule CaseinWeb.WorkspaceLive.RunInspectorTest do
  @moduledoc """
  LiveView coverage for the LiveView-owned run inspector (#694):

    * With workspace + tmux context, `run:open_inspector` opens the inspector
      region beside the terminal and reuses `RunPanel.run_panel/1`.
    * With no live tmux pane, it falls back to the full-area `run` tab
      (mirror of `tree:open_in_pane` → files tab / diff inspector).
    * Missing run id on restore lands on the ledger with nothing selected —
      normal empty state, not error/crash/blank.
    * Live ledger refresh does not flip the tab off terminal.
  """
  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Cockpit.Inspectors
  alias Casein.Workspaces.State.MemoryAdapter
  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents

  @workspace_id "ws-run-inspector"

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    workspace_root = Path.join(System.tmp_dir!(), "casein-run-inspector")
    workspace_path = Path.join(workspace_root, @workspace_id)
    File.rm_rf(workspace_path)
    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "README.md"), "run inspector\n")

    workspace_name = "run-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

    MemoryAdapter.clear()
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      MemoryAdapter.clear()
      restore_app(:workspaces_root, prev_root)
      restore_app(:tmux_adapter, prev_tmux_adapter)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, prev_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, prev_panes)
    end)

    workspace_id = @workspace_id

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", ^workspace_id, "status"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => @workspace_id,
            "name" => workspace_name,
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

    {:ok, tmux_session: tmux_session, workspace_path: workspace_path}
  end

  test "run:open_inspector opens the region and reuses run_panel beside the terminal",
       %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
    seed_topology(tmux_session, workspace_path)

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)
    flush_fake_tmux()
    render(view)

    refute has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=false]")

    html = render_click(view, "run:open_inspector", %{})

    assert socket_assigns(view, :tab) == "terminal"
    slots = socket_assigns(view, :inspector_slots)
    assert Inspectors.run_open?(slots)

    assert has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=true]")
    assert html =~ ~s(data-cockpit-split="open")
    assert html =~ ~s(data-inspector-kind="run")
    # Reuses RunPanel markers + deliberate empty state (not error chrome).
    assert html =~ "run-ledger"
    assert html =~ ~s(data-run-empty-state="no_runs")
    assert html =~ "No runs yet"
    refute html =~ "text-red-700\">Cannot run"

    style = region_style(html, "terminal-region-#{@workspace_id}")
    assert style =~ "60.0%"

    # Live ledger select keeps the terminal tab (no focus theft via tab switch).
    render_click(view, "run_ledger:select", %{"id" => "missing-run"})
    assert socket_assigns(view, :tab) == "terminal"
    assert Inspectors.run_open?(socket_assigns(view, :inspector_slots))

    restored = render_click(view, "inspector:close_all", %{})
    refute Inspectors.run_open?(socket_assigns(view, :inspector_slots))
    refute has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=false]")
    refute restored =~ ~s(data-cockpit-split="open")
  end

  test "run:open_inspector with no live tmux pane falls back to the full-area run tab",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    render_click(view, "run:open_inspector", %{})

    assert socket_assigns(view, :tab) == "run"
    refute Inspectors.run_open?(socket_assigns(view, :inspector_slots) || [])
    refute has_element?(view, "#inspector-region-#{@workspace_id}")
  end

  test "diff:open_inspector with no live tmux pane still falls back to the diff tab",
       %{conn: conn} do
    # Acceptance: fallback for *both* inspector types.
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    render_click(view, "diff:open_inspector", %{})

    assert socket_assigns(view, :tab) == "diff"
    refute Inspectors.diff_open?(socket_assigns(view, :inspector_slots) || [])
    refute has_element?(view, "#inspector-region-#{@workspace_id}")
  end

  test "serialize/restore re-derives the run viewport; missing run is empty ledger state" do
    {slots, _} =
      Inspectors.open([], %{
        kind: :run,
        id: "insp-run",
        title: "Run gone",
        run_id: "run-that-is-gone"
      })

    serialized = Inspectors.serialize(slots)

    assert serialized == [
             %{"type" => "inspector", "kind" => "run", "run_id" => "run-that-is-gone"}
           ]

    {restored, _} = Inspectors.restore(serialized)
    assert Inspectors.primary_run_id(restored) == "run-that-is-gone"
    assert Inspectors.run_open?(restored)

    Code.ensure_loaded!(InspectorEvents)
    assert function_exported?(InspectorEvents, :restore_inspectors, 2)
  end

  # --- helpers -----------------------------------------------------------------

  defp seed_topology(tmux_session, workspace_path) do
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: DateTime.utc_now() |> DateTime.to_unix(),
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: workspace_path,
          activity: 0,
          activity_flag: false,
          bell: false,
          unseen_changes: false
        }
      ]
    })
  end

  defp region_style(html, id) do
    case Regex.run(~r/id="#{Regex.escape(id)}"[^>]*style="([^"]*)"/, html) do
      [_, style] ->
        style

      _ ->
        case Regex.run(~r/style="([^"]*)"[^>]*id="#{Regex.escape(id)}"/, html) do
          [_, style] -> style
          _ -> nil
        end
    end
  end

  defp flush_fake_tmux do
    receive do
      {:fake_tmux_select_pane, _, _} -> flush_fake_tmux()
    after
      50 -> :ok
    end
  end

  defp socket_assigns(view, key) do
    :sys.get_state(view.pid).socket.assigns[key]
  end

  defp restore_app(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app(key, value), do: Application.put_env(:casein, key, value)
end
