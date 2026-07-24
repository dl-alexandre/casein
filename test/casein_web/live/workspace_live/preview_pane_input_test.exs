defmodule CaseinWeb.WorkspaceLive.PreviewPaneInputTest do
  # Preview runtime cutover: back/forward/refresh/close reach the LiveView as
  # generic "pane:input" events (the legacy "preview-pane:*" names remain as
  # thin translations for the session-bar buttons), dispatch through
  # Pane.impl(:preview).handle_input/2, and the resulting registration state
  # flows back via Casein.Panes.Events.
  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.PreviewPanes
  alias Casein.Workspaces.State.MemoryAdapter
  alias TmuxCtl.Test.FakeState

  @workspace_id "ws-1"
  @pane_id "%1"
  @tmux_session "devide_alpha_u-dev"

  setup do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "devide-preview-input-#{System.unique_integer([:positive])}"
      )

    workspace_path = Path.join(workspace_root, @workspace_id)
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    prev_persistence = Application.get_env(:casein, :preview_pane_persistence_enabled)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, TmuxCtl.Test.FakeAdapter)
    Application.put_env(:casein, :preview_pane_persistence_enabled, true)

    MemoryAdapter.clear()
    PreviewPanes.clear()

    FakeState.put(:fake_tmux_windows, %{
      @tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    FakeState.put(:fake_tmux_panes, %{
      @tmux_session => [
        %{
          id: @pane_id,
          window_id: "@0",
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

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", @workspace_id, "status"]} =
          conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => @workspace_id,
            "name" => "alpha",
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

    {:ok, _record} =
      Casein.Workspaces.State.sync(%Casein.Workspace{
        id: @workspace_id,
        name: "alpha",
        user: "dev",
        status: :running,
        path: workspace_path,
        metadata: %{raw: %{"user" => "dev"}}
      })

    on_exit(fn ->
      PreviewPanes.clear()
      MemoryAdapter.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      File.rm_rf(workspace_root)

      restore = fn
        key, nil -> Application.delete_env(:casein, key)
        key, val -> Application.put_env(:casein, key, val)
      end

      restore.(:workspaces_root, prev_root)
      restore.(:tmux_adapter, prev_tmux)
      restore.(:preview_pane_persistence_enabled, prev_persistence)
    end)

    {:ok, workspace_path: workspace_path}
  end

  defp register_pane!(workspace_path) do
    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => @pane_id,
               "url" => "http://localhost:5173/",
               "workspace_id" => @workspace_id,
               "cwd" => workspace_path,
               "tmux_session" => @tmux_session
             })

    registration
  end

  defp mount_view(conn) do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local")
    render_async(view, 5_000)
    _ = :sys.get_state(view.pid)
    view
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "pane:input drives preview history through the generic route", %{
    conn: conn,
    workspace_path: workspace_path
  } do
    register_pane!(workspace_path)

    view = mount_view(conn)

    # Mount hydration via Panes.snapshot/1 (reconnect parity with the legacy
    # preview loader).
    assert assigns(view).preview_panes[@pane_id][:url] == "http://localhost:5173/"
    assert %{type: :preview} = assigns(view).feature_panes[@pane_id]

    assert {:ok, _} = PreviewPanes.navigate(@pane_id, "/one")
    assert {:ok, _} = PreviewPanes.navigate(@pane_id, "/two")
    _ = render(view)
    assert assigns(view).preview_panes[@pane_id][:display_url] == "http://localhost:5173/two"

    # Back via the generic input event.
    render_click(view, "pane:input", %{"pane-id" => @pane_id, "type" => "go_back"})
    _ = render(view)

    assert assigns(view).preview_panes[@pane_id][:display_url] == "http://localhost:5173/one"
    assert assigns(view).entered_preview_pane_id == @pane_id
    pane_id = @pane_id

    assert_push_event(view, "devide:reload_preview_iframes", %{
      "pane_id" => ^pane_id,
      "force" => true
    })

    # The legacy session-bar event name still works as a thin translation.
    render_click(view, "preview-pane:forward", %{"pane-id" => @pane_id})
    _ = render(view)

    assert assigns(view).preview_panes[@pane_id][:display_url] == "http://localhost:5173/two"
  end

  test "pane:input close deregisters the pane and cleans the assigns", %{
    conn: conn,
    workspace_path: workspace_path
  } do
    register_pane!(workspace_path)

    view = mount_view(conn)
    assert Map.has_key?(assigns(view).preview_panes, @pane_id)

    render_click(view, "pane:input", %{"pane-id" => @pane_id, "type" => "close"})
    _ = render(view)

    refute Map.has_key?(assigns(view).preview_panes, @pane_id)
    refute Map.has_key?(assigns(view).feature_panes, @pane_id)
    assert PreviewPanes.get_by_pane(@pane_id) == nil
  end

  test "pane:input on an unknown pane is refused without crashing", %{conn: conn} do
    view = mount_view(conn)

    render_click(view, "pane:input", %{"pane-id" => "%99", "type" => "go_back"})

    assert render(view) =~ "workspace-main-header"
    assert Process.alive?(view.pid)
    refute Map.has_key?(assigns(view).preview_panes, "%99")
  end
end
