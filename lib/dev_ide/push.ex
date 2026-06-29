defmodule DevIDE.Push do
  @moduledoc """
  OS push fan-out for session alerts and high-priority mobile cards.

  Two collaborators:

    * `DevIDE.Push.Registry` — stores device push tokens per workspace
      (registered over `DevIdeWeb.SessionChannel` after the join authorized the
      identity for that workspace).
    * `DevIDE.Push.Dispatcher` — subscribes to the audit spine and the mobile
      card spine. It pushes alert-worthy audit events and newly-created
      high-priority `:needs_review` cards via the configured provider.

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
  defdelegate unregister(token), to: Registry
  defdelegate tokens_for(workspace_id), to: Registry
  defdelegate tokens_for_user(user_id), to: Registry

  @spec provider() :: module()
  def provider, do: Application.get_env(:dev_ide, :push_provider, DevIDE.Push.LogProvider)

  @spec ready_for?(String.t()) :: :ok | {:error, term()}
  def ready_for?(platform) do
    configured_for_provider?(provider(), platform)
  end

  defp configured_for_provider?(DevIDE.Push.LogProvider, _platform),
    do: {:error, :push_provider_unconfigured}

  defp configured_for_provider?(provider, platform) do
    cond do
      function_exported?(provider, :configured_for?, 1) ->
        provider.configured_for?(platform)

      function_exported?(provider, :configured?, 0) ->
        provider.configured?()

      true ->
        :ok
    end
  end
end
