defmodule DevIDE.Push.NativeProvider do
  @moduledoc """
  Platform router for native mobile push tokens.

  Android registers FCM tokens. iOS registers APNs tokens. The installed PWA
  registers a `"web"` Web Push subscription. Keeping that routing server-side lets
  the mobile channel and the browser continue to register `{platform, token}`
  without exposing provider-specific transport details — so native (APNs/FCM) and
  Web Push run side by side under a single configured provider.
  """
  @behaviour DevIDE.Push.Provider

  @impl true
  def push(token, platform, notification) when is_binary(token) do
    case normalize_platform(platform) do
      "android" -> DevIDE.Push.FCMProvider.push(token, platform, notification)
      "ios" -> DevIDE.Push.APNSProvider.push(token, platform, notification)
      "apns" -> DevIDE.Push.APNSProvider.push(token, platform, notification)
      "fcm" -> DevIDE.Push.FCMProvider.push(token, platform, notification)
      "web" -> DevIDE.Push.WebPushProvider.push(token, "web", notification)
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
      "web" -> DevIDE.Push.WebPushProvider.configured?()
      _other -> {:error, :unsupported_platform}
    end
  end

  defp normalize_platform(platform), do: platform |> to_string() |> String.downcase()
end
