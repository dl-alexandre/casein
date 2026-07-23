defmodule DevIDE.Push do
  @moduledoc """
  OS push fan-out for session alerts and high-priority mobile cards.

  Two collaborators:

    * `DevIDE.Push.Registry` — stores device push tokens per workspace
      (registered over `DevIdeWeb.SessionChannel` after the join authorized the
      identity for that workspace).
    * `DevIDE.Signals.AlertsRouter` — routes alert-worthy audit signals from
      `DevIDE.SignalBus` to the dispatcher when a workspace has registered tokens.
    * `DevIDE.Push.Dispatcher` — delivers OS pushes for routed audit alerts and
      newly-created high-priority `:needs_review` mobile cards via the configured
      provider.

  The provider is swappable (`config :dev_ide, :push_provider, ...`), defaulting
  to `DevIDE.Push.LogProvider`. `DevIDE.Push.NativeProvider` routes Android FCM
  tokens and iOS APNs tokens to the right transport without caller changes.

  Device note: native clients register OS push tokens over the user card stream
  for high-priority mobile cards, with workspace registration retained for
  workspace-scoped audit alerts.
  """

  alias DevIDE.Push.Registry

  defdelegate register(attrs), to: Registry
  defdelegate register_user(attrs), to: Registry
  defdelegate register_web(attrs), to: Registry
  defdelegate web_subscription(token), to: Registry
  defdelegate unregister(token), to: Registry
  defdelegate tokens_for(workspace_id), to: Registry
  defdelegate tokens_for_user(user_id), to: Registry
  defdelegate record_failure(token, reason), to: Registry
  defdelegate list_devices(opts \\ []), to: Registry
  defdelegate stats(), to: Registry

  @spec provider() :: module()
  def provider, do: Application.get_env(:dev_ide, :push_provider, DevIDE.Push.LogProvider)

  @spec ready_for?(String.t()) :: :ok | {:error, term()}
  def ready_for?(platform) do
    configured_for_provider?(provider(), platform)
  end

  defp configured_for_provider?(DevIDE.Push.LogProvider, _platform),
    do: {:error, :push_provider_unconfigured}

  defp configured_for_provider?(provider, platform) do
    with {:module, provider} <- Code.ensure_loaded(provider) do
      cond do
        function_exported?(provider, :configured_for?, 1) ->
          provider.configured_for?(platform)

        function_exported?(provider, :configured?, 0) ->
          provider.configured?()

        true ->
          :ok
      end
    else
      _ -> {:error, :push_provider_unconfigured}
    end
  end
end
