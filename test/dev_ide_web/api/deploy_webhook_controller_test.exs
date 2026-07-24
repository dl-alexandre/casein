defmodule CaseinWeb.API.DeployWebhookControllerTest do
  use CaseinWeb.ConnCase, async: false

  @secret "deploy-webhook-test-secret"
  @repo "dl-alexandre/dev_ide"

  setup %{conn: conn} do
    prev_deploy = Application.get_env(:dev_ide, :deployment)
    prev_trigger = Application.get_env(:dev_ide, :deploy_poller_trigger)
    parent = self()

    deployment =
      (prev_deploy || [])
      |> Keyword.put(:github_webhook_secret, @secret)
      |> Keyword.put(:github_repo, @repo)

    Application.put_env(:dev_ide, :deployment, deployment)

    Application.put_env(:dev_ide, :deploy_poller_trigger, fn _opts ->
      send(parent, :poller_triggered)
      :ok
    end)

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:dev_ide, :deployment, prev_deploy),
        else: Application.delete_env(:dev_ide, :deployment)

      if prev_trigger,
        do: Application.put_env(:dev_ide, :deploy_poller_trigger, prev_trigger),
        else: Application.delete_env(:dev_ide, :deploy_poller_trigger)
    end)

    {:ok, conn: conn}
  end

  test "returns 503 when the webhook secret is not configured", %{conn: conn} do
    prev_secret = System.get_env("DEVIDE_DEPLOY_WEBHOOK_SECRET")
    System.delete_env("DEVIDE_DEPLOY_WEBHOOK_SECRET")

    deployment =
      :dev_ide
      |> Application.get_env(:deployment, [])
      |> Keyword.delete(:github_webhook_secret)

    Application.put_env(:dev_ide, :deployment, deployment)

    on_exit(fn ->
      if prev_secret,
        do: System.put_env("DEVIDE_DEPLOY_WEBHOOK_SECRET", prev_secret),
        else: System.delete_env("DEVIDE_DEPLOY_WEBHOOK_SECRET")
    end)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/deploy_webhook", "{}")

    assert json_response(conn, 503) == %{"error" => "deploy_webhook_not_configured"}
  end

  test "returns 401 for missing or invalid signatures", %{conn: conn} do
    body = master_push_body()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "push")
      |> post(~p"/api/deploy_webhook", body)

    assert json_response(conn, 401) == %{"error" => "missing_signature"}

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", "push")
      |> put_req_header("x-hub-signature-256", "sha256=deadbeef")
      |> post(~p"/api/deploy_webhook", body)

    assert json_response(conn, 401) == %{"error" => "invalid_signature"}
  end

  test "triggers the poller for a signed master push", %{conn: conn} do
    body = master_push_body()

    conn =
      signed_push(conn, body)
      |> post(~p"/api/deploy_webhook", body)

    assert json_response(conn, 200) == %{"ok" => true, "triggered" => true}
    assert_receive :poller_triggered
  end

  test "ignores signed pushes to non-master branches", %{conn: conn} do
    body =
      Jason.encode!(%{
        "ref" => "refs/heads/feature/x",
        "repository" => %{"full_name" => @repo}
      })

    conn =
      signed_push(conn, body, "push")
      |> post(~p"/api/deploy_webhook", body)

    assert %{"ok" => true, "triggered" => false, "ignored" => ignored} = json_response(conn, 200)
    assert String.starts_with?(ignored, "non_deploy_branch:")
  end

  test "accepts GitHub ping events without triggering the poller", %{conn: conn} do
    body = ~s({"zen":"Keep it logically awesome."})

    conn =
      signed_push(conn, body, "ping")
      |> post(~p"/api/deploy_webhook", body)

    assert json_response(conn, 200) == %{"ok" => true, "triggered" => false, "ignored" => "ping"}
    refute_receive :poller_triggered, 50
  end

  test "returns 502 when the poller trigger fails", %{conn: conn} do
    Application.put_env(:dev_ide, :deploy_poller_trigger, fn _opts ->
      {:error, {:systemctl_failed, 1, "boom"}}
    end)

    body = master_push_body()

    conn =
      signed_push(conn, body)
      |> post(~p"/api/deploy_webhook", body)

    assert %{"ok" => false, "error" => error} = json_response(conn, 502)
    assert error =~ "systemctl_failed"
  end

  test "an accepted master push emits a correlated deploy.triggered root event", %{conn: conn} do
    :ok = Casein.Audit.clear()
    body = master_push_body()

    conn =
      signed_push(conn, body)
      |> post(~p"/api/deploy_webhook", body)

    assert %{"ok" => true, "triggered" => true} = json_response(conn, 200)
    assert_receive :poller_triggered

    [event] = Casein.Audit.recent_for("platform", 1)
    assert event.action == "deploy.triggered"
    assert event.actor_id == "github"
    assert event.metadata["result"] == "ok"
    assert is_binary(event.metadata["correlation_id"])

    assert [%{action: "deploy.triggered"}] =
             Casein.Audit.list_by_correlation(event.metadata["correlation_id"])
  end

  defp master_push_body do
    Jason.encode!(%{
      "ref" => "refs/heads/master",
      "repository" => %{"full_name" => @repo}
    })
  end

  defp signed_push(conn, body, event \\ "push") do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", event)
    |> put_req_header("x-hub-signature-256", sign(body, @secret))
  end

  defp sign(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end
end
