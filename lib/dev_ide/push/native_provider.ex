defmodule Casein.Push.NativeProvider do
  @moduledoc """
  Platform router for native mobile push tokens.

  Android registers FCM tokens. iOS registers APNs tokens. Keeping that routing
  server-side lets the mobile channel continue to register `{platform, token}`
  without exposing provider-specific transport details.
  """
  @behaviour Casein.Push.Provider

  @impl true
  def push(token, platform, notification) when is_binary(token) do
    case normalize_platform(platform) do
      "android" -> Casein.Push.FCMProvider.push(token, platform, notification)
      "ios" -> Casein.Push.APNSProvider.push(token, platform, notification)
      "apns" -> Casein.Push.APNSProvider.push(token, platform, notification)
      "fcm" -> Casein.Push.FCMProvider.push(token, platform, notification)
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
      _other -> {:error, :unsupported_platform}
    end
  end

  defp normalize_platform(platform), do: platform |> to_string() |> String.downcase()
end
