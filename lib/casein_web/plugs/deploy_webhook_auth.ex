defmodule CaseinWeb.Plugs.DeployWebhookAuth do
  @moduledoc """
  GitHub deploy-webhook authentication.

  Verifies `X-Hub-Signature-256` against the cached raw request body. This plug
  deliberately bypasses `ApiAuth` — GitHub signs the payload with a dedicated
  webhook secret, not the Casein API bearer token.
  """

  import Plug.Conn

  alias Casein.Deployment.GithubWebhook

  def init(opts), do: opts

  def call(conn, _opts) do
    case GithubWebhook.configured_secret() do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "deploy_webhook_not_configured"}))
        |> halt()

      secret ->
        authorize(conn, secret)
    end
  end

  defp authorize(conn, secret) do
    with {:ok, raw_body} <- raw_body(conn),
         :ok <-
           GithubWebhook.verify_signature(
             raw_body,
             signature_header(conn),
             secret
           ),
         {:ok, payload} <- decode_payload(raw_body) do
      assign(conn, :deploy_webhook_payload, payload)
    else
      {:error, :missing_body} ->
        deny(conn, 400, "missing_body")

      {:error, :missing_signature} ->
        deny(conn, 401, "missing_signature")

      {:error, :invalid_signature} ->
        deny(conn, 401, "invalid_signature")

      {:error, :invalid_json} ->
        deny(conn, 400, "invalid_json")
    end
  end

  defp raw_body(conn) do
    case conn.private[:casein_deploy_webhook_raw_body] do
      body when is_binary(body) -> {:ok, body}
      _ -> {:error, :missing_body}
    end
  end

  defp signature_header(conn) do
    conn
    |> get_req_header("x-hub-signature-256")
    |> List.first()
  end

  defp decode_payload(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = payload} -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp deny(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
