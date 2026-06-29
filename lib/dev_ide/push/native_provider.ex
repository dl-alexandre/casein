defmodule DevIDE.Push.NativeProvider do
  @moduledoc """
  Platform router for native mobile push tokens.

  Android registers FCM tokens. iOS registers APNs tokens. Keeping that routing
  server-side lets the mobile channel continue to register `{platform, token}`
  without exposing provider-specific transport details.
  """
  @behaviour DevIDE.Push.Provider

  @impl true
  def push(token, platform, notification) when is_binary(token) do
    case normalize_platform(platform) do
      "android" -> DevIDE.Push.FCMProvider.push(token, platform, notification)
      "ios" -> DevIDE.Push.APNSProvider.push(token, platform, notification)
      "apns" -> DevIDE.Push.APNSProvider.push(token, platform, notification)
      "fcm" -> DevIDE.Push.FCMProvider.push(token, platform, notification)
      _other -> {:error, :unsupported_platform}
    end
  end

  @impl true
  def configured_for?(platform) do
    case normalize_platform(platform) do
      "android" -> DevIDE.Push.FCMProvider.configured?()
      "fcm" -> DevIDE.Push.FCMProvider.configured?()
      "ios" -> DevIDE.Push.APNSProvider.configured?()
      "apns" -> DevIDE.Push.APNSProvider.configured?()
      _other -> {:error, :unsupported_platform}
    end
  end

  defp normalize_platform(platform), do: platform |> to_string() |> String.downcase()
end
