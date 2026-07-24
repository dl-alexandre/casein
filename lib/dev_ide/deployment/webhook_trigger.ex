defmodule Casein.Deployment.WebhookTrigger do
  @moduledoc """
  Handles verified GitHub deploy webhooks by starting the deploy poller unit.
  """

  alias Casein.Audit
  alias Casein.Deployment.{GithubWebhook, PollerTrigger}

  require Logger

  @spec handle(String.t() | nil, map() | nil) ::
          :ok | {:ignored, String.t()} | {:error, term()}
  def handle("ping", _payload), do: {:ignored, "ping"}

  def handle("push", payload) when is_map(payload) do
    case GithubWebhook.master_push?(payload) do
      :ok ->
        Logger.info("Casein deploy webhook accepted master push — starting poller")

        result = PollerTrigger.trigger()
        emit_triggered(result)
        result

      {:ignore, reason} ->
        {:ignored, reason}
    end
  end

  def handle(event, _payload) when is_binary(event), do: {:ignored, "unsupported_event:#{event}"}
  def handle(_event, _payload), do: {:ignored, "missing_event"}

  # Root provenance event for the deploy chain. The audit_events table
  # requires a workspace_id, so platform-level events use a sentinel; the
  # action is not in Alerts definitions, so no alert fires.
  defp emit_triggered(result) do
    Audit.emit!(%{
      workspace_id: "platform",
      actor_id: "github",
      action: "deploy.triggered",
      target_type: "service",
      target_ref: "deploy-poller",
      metadata: %{"result" => result_string(result)}
    })
  end

  defp result_string(:ok), do: "ok"
  defp result_string(other), do: inspect(other)
end
