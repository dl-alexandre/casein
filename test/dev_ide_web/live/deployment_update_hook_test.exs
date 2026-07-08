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

    # Isolate from the box's real poller status file: on the devbox an actual
    # deploy may be in flight, and its in-progress banner suppresses the
    # update banner this file asserts on. Tests that need a status file set
    # their own path on top of this.
    prev_deploy = Application.get_env(:dev_ide, :deployment)

    Application.put_env(
      :dev_ide,
      :deployment,
      (prev_deploy || [])
      |> Keyword.put(
        :last_deploy_path,
        Path.join(System.tmp_dir!(), "devide-no-deploy-#{System.unique_integer([:positive])}")
      )
    )

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:dev_ide, :deployment, prev_deploy),
        else: Application.delete_env(:dev_ide, :deployment)
    end)

    # The dashboard mount fetches the workspace list from the manager over HTTP;
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
    {:ok, view, _html} = live(conn, ~p"/")

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

  test "renders the deploy failure banner when the poller status file reports a gate failure",
       %{conn: conn} do
    path =
      Path.join(
        System.tmp_dir!(),
        "last-deploy-hook-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    record = %{
      "outcome" => "failed",
      "target_sha" => String.duplicate("c", 40),
      "target_short" => String.duplicate("c", 12),
      "phase" => "gate",
      "reason" => "pre-push gate failed",
      "started_at" => "2026-07-06T00:00:00Z",
      "finished_at" => "2026-07-06T00:05:00Z"
    }

    File.write!(path, Jason.encode!(record) <> "\n")

    prev_deploy = Application.get_env(:dev_ide, :deployment)
    prev_rev = System.get_env("DEVIDE_GIT_REVISION")

    Application.put_env(
      :dev_ide,
      :deployment,
      (prev_deploy || []) |> Keyword.put(:last_deploy_path, path)
    )

    System.put_env("DEVIDE_GIT_REVISION", String.duplicate("a", 40))

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:dev_ide, :deployment, prev_deploy),
        else: Application.delete_env(:dev_ide, :deployment)

      if prev_rev,
        do: System.put_env("DEVIDE_GIT_REVISION", prev_rev),
        else: System.delete_env("DEVIDE_GIT_REVISION")
    end)

    branch = "hook-failure-#{System.unique_integer([:positive])}"
    key = {DevIDE.Deployment.Drift, :remote_head, branch}
    remote = String.duplicate("c", 40)

    :persistent_term.put(key, {{:ok, remote}, System.monotonic_time(:millisecond)})

    prev_branch = System.get_env("DEV_IDE_GIT_BRANCH")
    System.put_env("DEV_IDE_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_branch_env("DEV_IDE_GIT_BRANCH", prev_branch)
      :persistent_term.erase(key)
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#deploy-failure-banner")
    assert render(view) =~ "pre-push gate"
    assert render(view) =~ String.duplicate("c", 12)
  end

  test "renders the in-progress banner when the poller status file reports an active deploy",
       %{conn: conn} do
    path =
      Path.join(
        System.tmp_dir!(),
        "last-deploy-progress-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    record = %{
      "outcome" => "in_progress",
      "target_sha" => String.duplicate("d", 40),
      "target_short" => String.duplicate("d", 12),
      "phase" => "gate",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(path, Jason.encode!(record) <> "\n")

    prev_deploy = Application.get_env(:dev_ide, :deployment)
    prev_rev = System.get_env("DEVIDE_GIT_REVISION")

    Application.put_env(
      :dev_ide,
      :deployment,
      (prev_deploy || []) |> Keyword.put(:last_deploy_path, path)
    )

    System.put_env("DEVIDE_GIT_REVISION", String.duplicate("a", 40))

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:dev_ide, :deployment, prev_deploy),
        else: Application.delete_env(:dev_ide, :deployment)

      if prev_rev,
        do: System.put_env("DEVIDE_GIT_REVISION", prev_rev),
        else: System.delete_env("DEVIDE_GIT_REVISION")
    end)

    branch = "hook-progress-#{System.unique_integer([:positive])}"
    key = {DevIDE.Deployment.Drift, :remote_head, branch}
    remote = String.duplicate("d", 40)

    :persistent_term.put(key, {{:ok, remote}, System.monotonic_time(:millisecond)})

    prev_branch = System.get_env("DEV_IDE_GIT_BRANCH")
    System.put_env("DEV_IDE_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_branch_env("DEV_IDE_GIT_BRANCH", prev_branch)
      :persistent_term.erase(key)
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#deploy-in-progress-banner")
    assert render(view) =~ "Running pre-push gate"
    assert render(view) =~ String.duplicate("d", 12)
  end

  test "a stale client_version connect param does NOT flag the banner (string check retired)",
       %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"client_version" => "some-stale-revision"})
      |> live(~p"/")

    # The retired git-revision handshake would have flagged here; static_changed?
    # now owns the "needs a hard reload" decision instead.
    assert :sys.get_state(view.pid).socket.assigns.update_available == false
    refute has_element?(view, "#deploy-update-banner")
  end

  defp restore_branch_env(key, nil), do: System.delete_env(key)
  defp restore_branch_env(key, value), do: System.put_env(key, value)
end
