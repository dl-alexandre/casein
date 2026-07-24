defmodule CaseinWeb.WorkspaceLive.Show.ViewDeepLinkTest do
  use Casein.TestCase, async: true

  alias CaseinWeb.WorkspaceLive.Show.ViewDeepLink

  test "workspace_view_path includes pane and zoom when multi-pane window is zoomed" do
    socket = %{
      assigns: %{
        workspace: %{id: "ws-1"},
        host_id: "local",
        terminal_sid: "u-dev-abc",
        tmux_active_window_id: "@0",
        tmux_active_pane_id: "%1",
        tmux_panes: [
          %{id: "%0", window_id: "@0"},
          %{id: "%1", window_id: "@0"}
        ],
        window_zoomed?: true
      }
    }

    path = ViewDeepLink.workspace_view_path(socket)

    assert path ==
             "/workspaces/ws-1?session=u-dev-abc&window=%400&pane=%251&zoom=1"
  end

  test "workspace_view_path uses the path route as the URL base" do
    socket = topology_socket(path_route: "/aws")

    assert ViewDeepLink.workspace_view_path(socket) ==
             "/aws?session=u-dev-abc&window=%400"
  end

  test "build_share_path requires pane when zoom is set" do
    path =
      ViewDeepLink.build_share_path("ws-1", "u-dev", "@0", pane: "%0", zoom: true)

    assert path =~ "pane=%250"
    assert path =~ "zoom=1"
  end

  test "terminal_idle? is true with no interaction clock" do
    assert ViewDeepLink.terminal_idle?(%{assigns: %{}})
  end

  test "terminal_idle? is false when interaction was recent" do
    now = System.monotonic_time(:millisecond)
    socket = %{assigns: %{terminal_last_interaction_ms: now}}

    refute ViewDeepLink.terminal_idle?(socket, ViewDeepLink.idle_patch_threshold_ms())
  end

  test "terminal_idle? is true after threshold elapses" do
    now = System.monotonic_time(:millisecond)
    socket = %{assigns: %{terminal_last_interaction_ms: now - 5_000}}

    assert ViewDeepLink.terminal_idle?(socket, 4_000)
  end

  test "maybe_patch_idle_view_url_connected seeds path without patching on first topology" do
    socket = topology_socket(patched_view_path: nil)
    path = ViewDeepLink.workspace_view_path(socket)

    result = ViewDeepLink.maybe_patch_idle_view_url_connected(socket)

    assert result.assigns.patched_view_path == path
  end

  test "maybe_patch_idle_view_url_connected skips when address bar already matches" do
    socket = topology_socket([])
    path = ViewDeepLink.workspace_view_path(socket)
    socket = topology_socket(patched_view_path: path)

    result = ViewDeepLink.maybe_patch_idle_view_url_connected(socket)

    assert result.assigns.patched_view_path == path
  end

  test "maybe_patch_idle_view_url_connected defers patch while operator is active" do
    now = System.monotonic_time(:millisecond)
    old_path = "/workspaces/ws-1?session=u-dev-abc&window=%400"

    socket =
      topology_socket(
        patched_view_path: old_path,
        terminal_last_interaction_ms: now,
        tmux_active_window_id: "@1",
        tmux_panes: [%{id: "%0", window_id: "@1"}]
      )

    result = ViewDeepLink.maybe_patch_idle_view_url_connected(socket)

    assert result.assigns.patched_view_path == old_path
  end

  test "maybe_patch_recovered_view_url patches when requested session is gone" do
    socket = topology_socket(patched_view_path: nil)

    result =
      ViewDeepLink.maybe_patch_recovered_view_url_connected(socket, %{"session" => "u-dev-stale"})

    assert result.assigns.patched_view_path == ViewDeepLink.workspace_view_path(result)
  end

  test "maybe_patch_recovered_view_url patches when requested window is gone" do
    socket = topology_socket(patched_view_path: nil)

    result =
      ViewDeepLink.maybe_patch_recovered_view_url_connected(socket, %{
        "session" => "u-dev-abc",
        "window" => "@9"
      })

    assert result.assigns.patched_view_path == ViewDeepLink.workspace_view_path(result)
  end

  test "maybe_patch_recovered_view_url is a no-op when the link still matches" do
    socket = topology_socket(patched_view_path: nil)
    path = ViewDeepLink.workspace_view_path(socket)
    socket = topology_socket(patched_view_path: path)

    result =
      ViewDeepLink.maybe_patch_recovered_view_url_connected(socket, %{
        "session" => "u-dev-abc",
        "window" => "@0"
      })

    assert result.assigns.patched_view_path == path
  end

  test "seed_patched_view_path records current view after URL navigation" do
    socket = topology_socket(patched_view_path: "/workspaces/ws-1?session=u-dev-abc&window=%400")

    result =
      socket
      |> put_in([Access.key!(:assigns), :tmux_active_window_id], "@1")
      |> put_in([Access.key!(:assigns), :tmux_panes], [%{id: "%0", window_id: "@1"}])
      |> ViewDeepLink.seed_patched_view_path()

    assert result.assigns.patched_view_path == ViewDeepLink.workspace_view_path(result)
  end

  defp topology_socket(overrides) do
    defaults = %{
      workspace: %{id: "ws-1"},
      host_id: "local",
      terminal_sid: "u-dev-abc",
      tmux_active_window_id: "@0",
      tmux_active_pane_id: "%0",
      tmux_topology_version: 1,
      tmux_panes: [%{id: "%0", window_id: "@0"}],
      window_zoomed?: false
    }

    %Phoenix.LiveView.Socket{
      endpoint: CaseinWeb.Endpoint,
      view: CaseinWeb.WorkspaceLive.Show,
      assigns: Map.merge(defaults, Map.new(overrides)) |> Map.put(:__changed__, %{}),
      redirected: nil
    }
  end
end
