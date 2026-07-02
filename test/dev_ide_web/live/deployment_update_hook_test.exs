defmodule DevIdeWeb.DeploymentUpdateHookTest do
  @moduledoc """
  Covers the deploy-update banner wiring in `DeploymentUpdateHook`.

  Two guarantees:

    * A runtime deploy push (`{:update_available, ...}` on `"deploy:updates"`)
      flips the banner on, and it actually renders — it lives in the :live
      layout (layouts/live.html.heex), which re-renders on connected diffs. (It
      used to live in the root layout, which is static after the disconnected
      mount, so the banner never appeared.)

    * There is NO connect-time git-revision comparison. Whether a reconnected
      client needs a hard reload is answered by `static_changed?/1` (the
      LiveViews redirect on it in mount); a version-string check would over-fire
      on code-only deploys and loop against the JS background-reconnect, so a
      stale `client_version` connect param must be ignored here.
  """
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Workspaces.State.MemoryAdapter
  alias DevIDE.Integrations.Manager.Client

  setup do
    MemoryAdapter.clear()

    # /workspaces mount fetches the workspace list from the manager over HTTP;
    # an empty list keeps the mount light — we only care about the on_mount hook.
    Req.Test.stub(DevIDE.Integrations.Manager.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "[]")
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
    end)

    :ok
  end

  test "renders the update banner when a deploy push arrives at runtime", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces")

    # No banner on a normal connect…
    refute has_element?(view, "#deploy-update-banner")

    # …until the draining instance broadcasts on the deploy topic. The banner is
    # in the :live layout, so it is part of the tracked render.
    Phoenix.PubSub.broadcast(DevIde.PubSub, "deploy:updates", {:update_available, "v2", 3})

    assert has_element?(view, "#deploy-update-banner")
    assert render(view) =~ "New version available"
    assert render(view) =~ "3"
    assert :sys.get_state(view.pid).socket.assigns.update_available == true
  end

  test "a stale client_version connect param does NOT flag the banner (string check retired)",
       %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"client_version" => "some-stale-revision"})
      |> live(~p"/workspaces")

    # The retired git-revision handshake would have flagged here; static_changed?
    # now owns the "needs a hard reload" decision instead.
    assert :sys.get_state(view.pid).socket.assigns.update_available == false
    refute has_element?(view, "#deploy-update-banner")
  end
end
