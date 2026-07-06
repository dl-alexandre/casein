defmodule DevIdeWeb.API.DeployWebhookController do
  @moduledoc "GitHub push webhook that starts the on-box deploy poller."

  use DevIdeWeb, :controller

  alias DevIDE.Deployment.WebhookTrigger

  def github(conn, _params) do
    event = github_event(conn)
    payload = conn.assigns[:deploy_webhook_payload]

    case DevIDE.Signals.Context.with_new(fn -> WebhookTrigger.handle(event, payload) end) do
      :ok ->
        json(conn, %{ok: true, triggered: true})

      {:ignored, reason} ->
        json(conn, %{ok: true, triggered: false, ignored: reason})

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(%{ok: false, error: format_error(reason)})
    end
  end

  defp github_event(conn) do
    conn
    |> get_req_header("x-github-event")
    |> List.first()
  end

  defp format_error({:systemctl_failed, status, output}) do
    "systemctl_failed(#{status}): #{output}"
  end

  defp format_error(reason), do: inspect(reason)
end
