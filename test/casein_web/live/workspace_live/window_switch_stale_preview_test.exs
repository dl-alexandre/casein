defmodule CaseinWeb.WorkspaceLive.WindowSwitchStalePreviewTest do
  @moduledoc """
  Reproduces the "window-switch stale-preview" bug.

  When the active tmux window changes, the window-scoped UI selection
  (`ui_highlight_pane_id` / `entered_preview_pane_id`) must be re-seated on the
  new window. If it is not, the prior window's pane id — typically a preview
  tile — strands: the window tab keeps showing the old window's preview marker
  even though the newly active window has no preview.

  Flow:
    1. Mount Show for a 2-window tmux session (`@0` shell / 1 pane, `@1` tests /
       3 panes). Window `@1` is active and contains preview pane `%2`.
    2. Register a preview pane on `%2` (the generic `{:pane_event, ...}`
       Casein.Panes.Events seam, which also makes `%2` the selected preview).
    3. Drive a real window switch to `@0` via the `tmux:select_window` event the
       LiveView handles (FakeTmuxAdapter flips the active window; the LiveView
       refreshes topology through `assign_tmux_topology`).
    4. Assert the preview chip now reflects window `@0` (no preview) — the chip
       for `%2` is gone and `@0` is the active window tab.

  The step-4 assertion FAILS on the pre-fix code (the chip strands on `%2`) and
  PASSES once the window-scoped selection is re-seated on the active-window
  change (commit 18f74c0 / branch fix/window-picker-stale-preview).
  """
  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Workspaces.State.MemoryAdapter
  alias Casein.Integrations.Manager.Client

  @workspace_id "ws-1"
  @preview_pane_id "%2"

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_test_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

    workspace_root = Path.join(System.tmp_dir!(), "devide-window-switch-stale-preview")
    workspace_path = Path.join(workspace_root, @workspace_id)
    File.mkdir_p!(workspace_path)

    workspace_name = "alpha-#{System.unique_integer([:positive])}"
    tmux_session = Casein.Terminals.Tmux.session_name(workspace_name, "u-dev")
    activity_now = DateTime.utc_now() |> DateTime.to_unix()

    MemoryAdapter.clear()
    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    # Window @0 (shell, 1 pane: %0) inactive; window @1 (tests, 3 panes) active.
    # %2 will be the preview pane and lives in @1.
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{
          id: "@0",
          index: 0,
          name: "shell",
          active: false,
          panes: 1,
          activity: activity_now - 120,
          current_command: "bash"
        },
        %{
          id: "@1",
          index: 1,
          name: "tests",
          active: true,
          panes: 3,
          activity: activity_now,
          current_command: "mix"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        pane("%0", "@0", index: 0, active: false, path: workspace_path),
        pane("%1", "@1", index: 0, active: true, path: workspace_path),
        pane("%3", "@1", index: 1, active: false, path: workspace_path),
        pane(@preview_pane_id, "@1", index: 2, active: false, path: workspace_path)
      ]
    })

    on_exit(fn ->
      File.rm_rf(workspace_root)
      MemoryAdapter.clear()

      restore_app(:workspaces_root, prev_root)
      restore_app(:tmux_adapter, prev_tmux_adapter)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, prev_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, prev_panes)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, prev_test_pid)
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

  test "window switch re-seats the preview selection so the picker chip is not stale",
       %{conn: conn, tmux_session: tmux_session} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{@workspace_id}?host=local&window=@1")
    render_async(view, 5_000)

    # Initially active window is @1, which holds the preview pane %2.
    assert socket_assigns(view, :tmux_active_window_id) == "@1"

    # Register a preview pane on %2. This is the path the running viewer uses
    # when a preview pane comes online; it also selects %2 as the highlighted
    # pane, so the window picker renders its preview chip.
    register_preview_pane(view, @preview_pane_id, "http://localhost:5173/")

    assert socket_assigns(view, :preview_panes)[@preview_pane_id][:display_url] ==
             "http://localhost:5173/"

    # Drive a real window switch to @0 (shell, 1 pane, NO preview) the way the
    # LiveView receives it: the picker's phx-click="tmux:select_window".
    render_click(view, "tmux:select_window", %{"window-id" => "@0"})
    assert_receive {:fake_tmux_select_window, ^tmux_session, "@0"}

    # The active window really changed.
    assert socket_assigns(view, :tmux_active_window_id) == "@0",
           "expected the active window to switch to @0"

    # @0 is now the active window tab and @1 is not.
    assert has_element?(view, "#tmux-window--0 a", "shell")
    refute has_element?(view, "#tmux-window--1[data-picker-active]")

    # CORE ASSERTION — the stale-preview bug.
    #

    # And the stale pane id must no longer be the resolved highlight either.
    refute socket_assigns(view, :entered_preview_pane_id) == @preview_pane_id,
           "stale entered_preview_pane_id still points at the previous window's preview pane"
  end

  defp pane(id, window_id, opts) do
    %{
      id: id,
      window_id: window_id,
      index: Keyword.get(opts, :index, 0),
      active: Keyword.get(opts, :active, false),
      left: 0,
      top: 0,
      width: 120,
      height: 40,
      current_command: "bash",
      current_path: Keyword.get(opts, :path, "/tmp"),
      activity: 0,
      activity_flag: false,
      bell: false,
      unseen_changes: false
    }
  end

  # Preview lifecycle reaches the LiveView through the generic
  # Casein.Panes.Events channel since the preview runtime cutover.
  defp register_preview_pane(view, pane_id, url) do
    send(
      view.pid,
      {:pane_event,
       %{
         reason: :registered,
         type: :preview,
         pane_id: pane_id,
         workspace_id: @workspace_id,
         tmux_session: nil,
         payload: %{
           workspace_id: @workspace_id,
           url: url,
           display_url: url,
           preview_id: 1,
           control_session_id: 1,
           viewport: nil
         }
       }}
    )

    render(view)
  end

  defp socket_assigns(view, key) do
    :sys.get_state(view.pid).socket.assigns[key]
  end

  defp restore_app(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app(key, value), do: Application.put_env(:casein, key, value)
end
