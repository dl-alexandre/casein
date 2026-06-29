defmodule DevIDE.Push.LogProvider do
  @moduledoc """
  Default `DevIDE.Push.Provider` — logs instead of delivering. Lets the whole
  registry → dispatcher → provider pipeline run and be tested before a real
  APNs/FCM adapter (and provider credentials) exist. Tokens are redacted.
  """
  @behaviour DevIDE.Push.Provider

  require Logger

  @impl true
  def push(token, platform, notification) do
    Logger.info(
      "[push:#{platform}] #{notification[:title]} " <>
        "ws=#{notification[:workspace_id]} → #{redact(token)}"
    )

    :ok
  end

  defp redact(token) when is_binary(token) and byte_size(token) > 6,
    do: binary_part(token, 0, 6) <> "…"

  defp redact(_token), do: "…"
end
