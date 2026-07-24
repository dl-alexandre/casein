defmodule CaseinWeb.DeploymentUpdateHookTest do
  @moduledoc """
  Covers deploy-state wiring in `DeploymentUpdateHook`.

  Two guarantees:

    * A runtime deploy push (`{:update_available, ...}` on `"deploy:updates"`)
      flips the notifications bell dot and surfaces a System card in the drawer.

    * There is NO connect-time git-revision comparison. Whether a reconnected
      client needs a hard reload is answered by `static_changed?/1` (the
      LiveViews redirect on it in mount); a version-string check would over-fire
      on code-only deploys and loop against the JS background-reconnect, so a
      stale `client_version` connect param must be ignored here.
  """
  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()

    prev_watch = System.get_env("DEV_IDE_DEPLOY_POLLER_WATCH")
    System.put_env("DEV_IDE_DEPLOY_POLLER_WATCH", "0")

    on_exit(fn ->
      if prev_watch,
        do: System.put_env("DEV_IDE_DEPLOY_POLLER_WATCH", prev_watch),
        else: System.delete_env("DEV_IDE_DEPLOY_POLLER_WATCH")
    end)

    # Isolate from the box's real poller status file: on the devbox an actual
    # deploy may be in flight, and its in-progress signal suppresses the
    # update card this file asserts on. Tests that need a status file set
    # their own path on top of this.
    prev_deploy = Application.get_env(:casein, :deployment)

    Application.put_env(
      :casein,
      :deployment,
      (prev_deploy || [])
      |> Keyword.put(
        :last_deploy_path,
        Path.join(System.tmp_dir!(), "devide-no-deploy-#{System.unique_integer([:positive])}")
      )
    )

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:casein, :deployment, prev_deploy),
        else: Application.delete_env(:casein, :deployment)
    end)

    # The dashboard mount fetches the workspace list from the manager over HTTP;
    # an empty list keeps the mount light — we only care about the on_mount hook.
    Req.Test.stub(Casein.Integrations.Manager.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "[]")
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
    end)

    :ok
  end

  test "surfaces update state on the bell and in the drawer when a deploy push arrives at runtime",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert :sys.get_state(view.pid).socket.assigns.update_available == false

    Phoenix.PubSub.broadcast(Casein.PubSub, "deploy:updates", {:update_available, "v2", 3})

    assert :sys.get_state(view.pid).socket.assigns.update_available == true

    view |> element("#notifications-open-__scratch__") |> render_click()

    assert has_element?(view, "#deploy-system-update")
    assert render(view) =~ "New version available"
    assert render(view) =~ "3"
    assert has_element?(view, "#deploy-update-now")
  end

  test "surfaces deploy failure on the bell and in the drawer when the poller status file reports a gate failure",
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

    prev_deploy = Application.get_env(:casein, :deployment)
    prev_rev = System.get_env("DEVIDE_GIT_REVISION")

    Application.put_env(
      :casein,
      :deployment,
      (prev_deploy || []) |> Keyword.put(:last_deploy_path, path)
    )

    System.put_env("DEVIDE_GIT_REVISION", String.duplicate("a", 40))

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:casein, :deployment, prev_deploy),
        else: Application.delete_env(:casein, :deployment)

      if prev_rev,
        do: System.put_env("DEVIDE_GIT_REVISION", prev_rev),
        else: System.delete_env("DEVIDE_GIT_REVISION")
    end)

    branch = "hook-failure-#{System.unique_integer([:positive])}"
    key = {Casein.Deployment.Drift, :remote_head, branch}
    remote = String.duplicate("c", 40)

    :persistent_term.put(key, {{:ok, remote}, System.monotonic_time(:millisecond)})

    prev_branch = System.get_env("DEV_IDE_GIT_BRANCH")
    System.put_env("DEV_IDE_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_branch_env("DEV_IDE_GIT_BRANCH", prev_branch)
      :persistent_term.erase(key)
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#notifications-open-__scratch__") |> render_click()

    assert has_element?(view, "#deploy-system-failure")
    assert render(view) =~ "pre-push gate"
    assert render(view) =~ String.duplicate("c", 12)
  end

  test "surfaces in-progress deploy state on the bell and in the drawer when the poller status file reports an active deploy",
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

    prev_deploy = Application.get_env(:casein, :deployment)
    prev_rev = System.get_env("DEVIDE_GIT_REVISION")

    Application.put_env(
      :casein,
      :deployment,
      (prev_deploy || []) |> Keyword.put(:last_deploy_path, path)
    )

    System.put_env("DEVIDE_GIT_REVISION", String.duplicate("a", 40))

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:casein, :deployment, prev_deploy),
        else: Application.delete_env(:casein, :deployment)

      if prev_rev,
        do: System.put_env("DEVIDE_GIT_REVISION", prev_rev),
        else: System.delete_env("DEVIDE_GIT_REVISION")
    end)

    branch = "hook-progress-#{System.unique_integer([:positive])}"
    key = {Casein.Deployment.Drift, :remote_head, branch}
    remote = String.duplicate("d", 40)

    :persistent_term.put(key, {{:ok, remote}, System.monotonic_time(:millisecond)})

    prev_branch = System.get_env("DEV_IDE_GIT_BRANCH")
    System.put_env("DEV_IDE_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_branch_env("DEV_IDE_GIT_BRANCH", prev_branch)
      :persistent_term.erase(key)
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#notifications-open-__scratch__") |> render_click()

    assert has_element?(view, "#deploy-system-in-progress")
    assert render(view) =~ "Running pre-push gate"
    assert render(view) =~ String.duplicate("d", 12)
  end

  test "a deploy_reconnect broadcast pushes a background-reconnect event to the client",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(Casein.PubSub, "deploy:updates", {:deploy_reconnect})

    assert_push_event(view, "devide:deploy_reconnect", %{})
  end

  test "a stale client_version connect param does NOT flag update state (string check retired)",
       %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"client_version" => "some-stale-revision"})
      |> live(~p"/")

    # Drift or poller status may still light the bell dot; this test only
    # guards the retired connect-time update_available handshake.
    assert :sys.get_state(view.pid).socket.assigns.update_available == false
  end

  defp restore_branch_env(key, nil), do: System.delete_env(key)
  defp restore_branch_env(key, value), do: System.put_env(key, value)
end
