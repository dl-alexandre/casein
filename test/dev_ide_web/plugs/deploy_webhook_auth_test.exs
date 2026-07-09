defmodule DevIdeWeb.Plugs.DeployWebhookAuthTest do
  use DevIDE.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias DevIdeWeb.Plugs.DeployWebhookAuth

  @secret "webhook-test-secret"
  @body ~s({"ref":"refs/heads/master"})

  setup do
    prev = Application.get_env(:dev_ide, :deployment)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, :deployment)
        val -> Application.put_env(:dev_ide, :deployment, val)
      end
    end)

    :ok
  end

  defp put_secret(secret) do
    Application.put_env(
      :dev_ide,
      :deployment,
      Keyword.put(Application.get_env(:dev_ide, :deployment, []), :github_webhook_secret, secret)
    )
  end

  defp clear_secret do
    config = Application.get_env(:dev_ide, :deployment, []) |> Keyword.delete(:github_webhook_secret)
    Application.put_env(:dev_ide, :deployment, config)
    System.delete_env("DEVIDE_DEPLOY_WEBHOOK_SECRET")
  end

  defp sign(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end

  defp build_conn(body, headers \\ []) do
    conn =
      :post
      |> conn("/hooks/deploy", body)
      |> put_private(:devide_deploy_webhook_raw_body, body)

    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  test "halts 503 when the deploy webhook secret is not configured" do
    clear_secret()

    conn = build_conn(@body) |> DeployWebhookAuth.call([])

    assert conn.halted
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"error" => "deploy_webhook_not_configured"}
  end

  test "halts 400 when the raw body is missing" do
    put_secret(@secret)

    conn =
      :post
      |> conn("/hooks/deploy", "")
      |> DeployWebhookAuth.call([])

    assert conn.halted
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "missing_body"}
  end

  test "halts 401 when the signature header is missing" do
    put_secret(@secret)

    conn = build_conn(@body) |> DeployWebhookAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "missing_signature"}
  end

  test "halts 401 when the signature is invalid" do
    put_secret(@secret)

    conn =
      build_conn(@body, [{"x-hub-signature-256", "sha256=deadbeef"}])
      |> DeployWebhookAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_signature"}
  end

  test "halts 400 when the body is not valid JSON" do
    put_secret(@secret)
    body = "not-json"

    conn =
      build_conn(body, [{"x-hub-signature-256", sign(body, @secret)}])
      |> DeployWebhookAuth.call([])

    assert conn.halted
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_json"}
  end

  test "assigns the payload when the signature is valid" do
    put_secret(@secret)

    conn =
      build_conn(@body, [{"x-hub-signature-256", sign(@body, @secret)}])
      |> DeployWebhookAuth.call([])

    refute conn.halted
    assert conn.assigns.deploy_webhook_payload == %{"ref" => "refs/heads/master"}
  end
end
