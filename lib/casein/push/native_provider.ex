defmodule Casein.Push.NativeProvider do
  @moduledoc """
  Platform router for native mobile push tokens.

  Android registers FCM tokens. iOS registers APNs tokens. The installed PWA
  registers a `"web"` Web Push subscription. Keeping that routing server-side lets
  the mobile channel and the browser continue to register `{platform, token}`
  without exposing provider-specific transport details — so native (APNs/FCM) and
  Web Push run side by side under a single configured provider.
  """
  @behaviour Casein.Push.Provider

  @impl true
  def push(token, platform, notification) when is_binary(token) do
    case normalize_platform(platform) do
      "android" -> Casein.Push.FCMProvider.push(token, platform, notification)
      "ios" -> Casein.Push.APNSProvider.push(token, platform, notification)
      "apns" -> Casein.Push.APNSProvider.push(token, platform, notification)
      "fcm" -> Casein.Push.FCMProvider.push(token, platform, notification)
      "web" -> Casein.Push.WebPushProvider.push(token, "web", notification)
      _other -> {:error, :unsupported_platform}
    end
  end

  @impl true
  def configured_for?(platform) do
    case normalize_platform(platform) do
      "android" -> Casein.Push.FCMProvider.configured?()
      "fcm" -> Casein.Push.FCMProvider.configured?()
      "ios" -> Casein.Push.APNSProvider.configured?()
      "apns" -> Casein.Push.APNSProvider.configured?()
      "web" -> Casein.Push.WebPushProvider.configured?()
      _other -> {:error, :unsupported_platform}
    end
  end

  defp normalize_platform(platform), do: platform |> to_string() |> String.downcase()
end
