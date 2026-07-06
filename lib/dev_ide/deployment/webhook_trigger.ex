defmodule DevIDE.Deployment.WebhookTrigger do
  @moduledoc """
  Handles verified GitHub deploy webhooks by starting the deploy poller unit.
  """

  alias DevIDE.Deployment.{GithubWebhook, PollerTrigger}

  require Logger

  @spec handle(String.t() | nil, map() | nil) ::
          :ok | {:ignored, String.t()} | {:error, term()}
  def handle("ping", _payload), do: {:ignored, "ping"}

  def handle("push", payload) when is_map(payload) do
    case GithubWebhook.master_push?(payload) do
      :ok ->
        Logger.info("DevIDE deploy webhook accepted master push — starting poller")

        PollerTrigger.trigger()

      {:ignore, reason} ->
        {:ignored, reason}
    end
  end

  def handle(event, _payload) when is_binary(event), do: {:ignored, "unsupported_event:#{event}"}
  def handle(_event, _payload), do: {:ignored, "missing_event"}
end
