defmodule CaseinWeb.WorkspaceLive.InspectorRegionTest do
  @moduledoc """
  LiveView coverage for the Casein-owned terminal|inspector split (#690):

    * Opening a LiveView-owned inspector renders `#inspector-region-*` and
      shrinks the terminal region (class/style change).
    * Closing the last inspector restores the terminal region to full size.
    * A synthetic Ghostty `resize` after open is accepted by the host path
      (ResizeObserver → pushEvent("resize") is the production path; we assert
      the server accepts the resulting event while the split is open).
    * An agent surface request via `Casein.Cockpit.Inspectors.request_open/2`
      is picked up by a mounted cockpit.
  """
  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Cockpit.Geometry
  alias Casein.Cockpit.Inspectors
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-inspector-region"

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)

    workspace_root = Path.join(System.tmp_dir!(), "casein-inspector-region")
    workspace_path = Path.join(workspace_root, @workspace_id)
    File.rm_rf(workspace_path)
    File.mkdir_p!(workspace_path)

    workspace_name = "insp-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")

    MemoryAdapter.clear()
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    on_exit(fn ->
      File.rm_rf(workspace_root)
      MemoryAdapter.clear()
      restore_app(:workspaces_root, prev_root)
      restore_app(:tmux_adapter, prev_tmux_adapter)
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

    seed_topology(tmux_session, workspace_path)

    {:ok, tmux_session: tmux_session, workspace_path: workspace_path}
  end

  test "opening an inspector renders the region and shrinks the terminal region",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    refute has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=false]")
    refute render(view) =~ ~s(data-cockpit-split="open")

    render_click(view, "inspector:open", %{
      "id" => "insp-diff-1",
      "kind" => "diff",
      "title" => "Diff side-by-side"
    })

    html = render(view)

    assert has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#inspector-pane-insp-diff-1")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=true]")
    assert html =~ ~s(data-cockpit-split="open")
    assert html =~ "Diff side-by-side"

    terminal_style = region_style(html, "terminal-region-#{@workspace_id}")
    assert terminal_style =~ "60.0%"
    inspector_style = region_style(html, "inspector-region-#{@workspace_id}")
    assert inspector_style =~ "40.0%"

    # Closing the last inspector restores full terminal region.
    render_click(view, "inspector:close", %{"id" => "insp-diff-1"})
    restored = render(view)

    refute has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=false]")
    refute restored =~ ~s(data-cockpit-split="open")
    restored_style = region_style(restored, "terminal-region-#{@workspace_id}")
    refute restored_style && String.contains?(restored_style, "60.0%")
  end

  test "agent surface request opens the inspector on a mounted cockpit", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    :ok =
      Inspectors.request_open(@workspace_id, %{
        id: "insp-from-agent",
        kind: :diff,
        title: "Agent-surfaced diff"
      })

    # Deliver the PubSub message into the LiveView mailbox.
    Casein.Test.Eventually.await(
      fn -> render(view) =~ "Agent-surfaced diff" && true end,
      timeout_ms: 2_000,
      interval_ms: 15,
      message: "agent-surfaced inspector title never appeared"
    )

    assert has_element?(view, "#inspector-pane-insp-from-agent")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=true]")
  end

  test "resize after inspector open is accepted by the Ghostty host path",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)

    ghostty_id = find_ghostty_id(html) || find_ghostty_id(render(view))

    render_click(view, "inspector:open", %{
      "id" => "insp-resize",
      "kind" => "diff",
      "title" => "Resize probe"
    })

    open_html = render(view)
    assert open_html =~ ~s(data-inspector-open="true")

    cols = 48
    rows = 24

    if is_binary(ghostty_id) do
      view
      |> element("##{ghostty_id}")
      |> render_hook("resize", %{"cols" => cols, "rows" => rows})
    else
      # Fallback: the component host path the Ghostty hook uses.
      send(view.pid, {:terminal_resize, "pane-1", cols, rows})
      render(view)
    end

    assert has_element?(view, "#inspector-region-#{@workspace_id}")
    assert has_element?(view, "#terminal-region-#{@workspace_id}[data-inspector-open=true]")

    # Prefer proving the LiveView recorded a post-open size when the host
    # tracks it; at minimum the resize must not crash the split.
    assigns = :sys.get_state(view.pid).socket.assigns
    assert Geometry.inspector_open?(assigns.cockpit_geometry)
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

  defp find_ghostty_id(html) when is_binary(html) do
    case Regex.run(~r/id="(ghostty-[^"]+)"/, html) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp find_ghostty_id(_), do: nil

  defp restore_app(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app(key, value), do: Application.put_env(:casein, key, value)
end
