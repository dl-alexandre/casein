defmodule DevIdeWeb.DeploymentUpdateHookTest do
  @moduledoc """
  Verifies the passive version-handshake safety net: when a browser reconnects
  onto an instance running a different revision than the page was served with,
  `DeploymentUpdateHook.maybe_flag_version_mismatch/1` flips the update banner
  on. This is the gap-1 path (old instance died before it could broadcast its
  drain) and is exercised here by driving real connect params through the hook.

  Also guards the rendering fix: the banner lives in the :live layout
  (layouts/live.html.heex), which re-renders on connected diffs. It used to live
  in the root layout, which is static after the disconnected mount, so the banner
  never actually appeared — these tests assert it now renders both from the
  connect-time mismatch and from a runtime deploy push.
  """
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Workspaces.State.MemoryAdapter

  @server_version "server-revision-aaaa"

  setup do
    bypass = Bypass.open()
    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_revision = System.get_env("DEVIDE_GIT_REVISION")

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    # Pin the running instance's version so the mismatch is deterministic and
    # independent of the checked-out app vsn / ambient env.
    System.put_env("DEVIDE_GIT_REVISION", @server_version)
    MemoryAdapter.clear()

    # /workspaces mount fetches the workspace list from the manager over HTTP;
    # an empty list keeps the mount light — we only care about the on_mount hook.
    Bypass.stub(bypass, "GET", "/api/workspaces", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "[]")
    end)

    on_exit(fn ->
      MemoryAdapter.clear()

      if prev_manager,
        do: Application.put_env(:dev_ide, :manager_url, prev_manager),
        else: Application.delete_env(:dev_ide, :manager_url)

      if prev_revision,
        do: System.put_env("DEVIDE_GIT_REVISION", prev_revision),
        else: System.delete_env("DEVIDE_GIT_REVISION")
    end)

    {:ok, bypass: bypass}
  end

  test "renders the update banner when the client was served an older revision", %{conn: conn} do
    assert DevIDE.Deployment.Version.version() == @server_version

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"client_version" => "stale-revision-zzzz"})
      |> live(~p"/workspaces")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.update_available == true
    assert assigns.update_reason == :version_mismatch

    # The banner is in the :live layout, so it is part of the tracked render.
    assert has_element?(view, "#deploy-update-banner")
    assert render(view) =~ "New version available"
  end

  test "renders the update banner when a deploy push arrives at runtime", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"client_version" => @server_version})
      |> live(~p"/workspaces")

    # No banner on connect (versions match)…
    refute has_element?(view, "#deploy-update-banner")

    # …until the draining instance broadcasts on the deploy topic. This is the
    # existing drain path, which was silently broken while the banner lived in
    # the static root layout.
    Phoenix.PubSub.broadcast(DevIde.PubSub, "deploy:updates", {:update_available, "v2", 3})

    assert render(view) =~ "deploy-update-banner"
    assert render(view) =~ "Update starting"
    assert render(view) =~ "3"
  end

  test "does not flag when the client is on the same revision as the server", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"client_version" => @server_version})
      |> live(~p"/workspaces")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.update_available == false
    assert assigns.update_reason == nil
    refute has_element?(view, "#deploy-update-banner")
  end

  test "does not flag on a missing or unknown client version (no false positive)", %{conn: conn} do
    {:ok, missing_view, _html} =
      conn
      |> put_connect_params(%{})
      |> live(~p"/workspaces")

    assert :sys.get_state(missing_view.pid).socket.assigns.update_available == false
    refute has_element?(missing_view, "#deploy-update-banner")

    {:ok, unknown_view, _html} =
      conn
      |> put_connect_params(%{"client_version" => "unknown"})
      |> live(~p"/workspaces")

    assert :sys.get_state(unknown_view.pid).socket.assigns.update_available == false
    refute has_element?(unknown_view, "#deploy-update-banner")
  end
end
