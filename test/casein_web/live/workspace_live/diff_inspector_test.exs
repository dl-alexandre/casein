defmodule CaseinWeb.WorkspaceLive.DiffInspectorTest do
  @moduledoc """
  LiveView coverage for the LiveView-owned diff inspector (#691) on the #690
  foundation:

    * With workspace + tmux context, `diff:open_inspector` opens the inspector
      region beside the terminal and reuses `SidePanels.diff_panel/1`.
    * With no live tmux pane, it falls back to the full-area `diff` tab
      (mirror of `tree:open_in_pane` → files tab).
    * Session-template serialize/restore re-derives the viewport (path only).
  """
  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Cockpit.Inspectors
  alias Casein.Workspaces.State.MemoryAdapter
  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents

  @workspace_id "ws-diff-inspector"

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    workspace_root = Path.join(System.tmp_dir!(), "casein-diff-inspector")
    workspace_path = Path.join(workspace_root, @workspace_id)
    File.rm_rf(workspace_path)
    File.mkdir_p!(Path.join(workspace_path, "lib"))
    File.write!(Path.join(workspace_path, "lib/foo.ex"), "defmodule Foo do\nend\n")

    System.cmd("git", ["init"], cd: workspace_path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace_path)
    System.cmd("git", ["config", "user.name", "Test"], cd: workspace_path)
    System.cmd("git", ["add", "lib/foo.ex"], cd: workspace_path)
    System.cmd("git", ["commit", "-m", "init"], cd: workspace_path, stderr_to_stdout: true)

    File.write!(
      Path.join(workspace_path, "lib/foo.ex"),
      "defmodule Foo do\n  def x, do: 1\nend\n"
    )

    workspace_name = "diff-#{System.unique_integer([:positive])}"
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

  test "diff:open_inspector opens the region and reuses diff_panel beside the terminal",
       %{conn: conn, tmux_session: tmux_session, workspace_path: workspace_path} do
    seed_topology(tmux_session, workspace_path)

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)
    flush_fake_tmux()
    render(view)

    refute has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=false]")

    html = render_click(view, "diff:open_inspector", %{"path" => "lib/foo.ex"})

    assert socket_assigns(view, :tab) == "terminal"
    slots = socket_assigns(view, :inspector_slots)
    assert Inspectors.diff_open?(slots)
    assert Inspectors.primary_diff_path(slots) == "lib/foo.ex"

    assert has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=true]")
    assert html =~ ~s(data-cockpit-split="open")
    assert html =~ ~s(data-inspector-kind="diff")
    # Reuses SidePanels.diff_panel markers.
    assert html =~ "Changes"
    assert html =~ "lib/foo.ex"

    style = region_style(html, "terminal-region-#{@workspace_id}")
    assert style =~ "60.0%"

    restored = render_click(view, "inspector:close_all", %{})
    refute Inspectors.diff_open?(socket_assigns(view, :inspector_slots))
    refute has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=false]")
    refute restored =~ ~s(data-cockpit-split="open")
  end

  test "diff:open_inspector with no live tmux pane falls back to the full-area diff tab",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    render_click(view, "diff:open_inspector", %{"path" => "lib/foo.ex"})

    assert socket_assigns(view, :tab) == "diff"
    assert %{path: "lib/foo.ex"} = socket_assigns(view, :open_file)
    refute Inspectors.diff_open?(socket_assigns(view, :inspector_slots) || [])
    refute has_element?(view, "#inspector-region-#{@workspace_id}")
  end

  test "serialize/restore re-derives the diff viewport from path only" do
    {slots, _} =
      Inspectors.open([], %{kind: :diff, id: "insp-diff", title: "lib/foo.ex", path: "lib/foo.ex"})

    serialized = Inspectors.serialize(slots)
    assert serialized == [%{"type" => "inspector", "kind" => "diff", "path" => "lib/foo.ex"}]

    {restored, _} = Inspectors.restore(serialized)
    assert Inspectors.primary_diff_path(restored) == "lib/foo.ex"
    assert Inspectors.diff_open?(restored)

    Code.ensure_loaded!(InspectorEvents)
    assert function_exported?(InspectorEvents, :restore_inspectors, 2)
  end

  test "session-template inspectors fragment round-trips through serialize/restore" do
    serialized = [%{"type" => "inspector", "kind" => "diff", "path" => "lib/foo.ex"}]

    # Export body shape matches Casein.Cockpit.Inspectors.serialize/1.
    {slots, _} =
      Inspectors.open([], %{kind: :diff, id: "insp-diff", title: "lib/foo.ex", path: "lib/foo.ex"})

    assert Inspectors.serialize(slots) == serialized

    {restored, geo} = Inspectors.restore(serialized)
    assert Casein.Cockpit.Geometry.inspector_open?(geo)
    assert Inspectors.diff_open?(restored)
    assert Inspectors.primary_diff_path(restored) == "lib/foo.ex"
    # Fresh id — identity is not durable across template restore.
    refute hd(restored).id == "insp-diff"
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
