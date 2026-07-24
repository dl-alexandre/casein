defmodule Casein.Push.Diagnostics do
  @moduledoc """
  Readiness diagnostics for native push delivery.

  This is intentionally a configuration check, not a send probe: it verifies
  that the configured server provider has enough platform-specific setup to
  attempt delivery without minting tokens or contacting APNs/FCM.
  """

  alias Casein.Push

  @default_platforms ["android", "ios"]

  @type platform_status :: %{
          platform: String.t(),
          status: :ready | :not_ready,
          reason: term() | nil,
          hint: String.t() | nil
        }

  @spec report([String.t()]) :: %{
          provider: module(),
          ready?: boolean(),
          platforms: [platform_status()]
        }
  def report(platforms \\ @default_platforms) do
    platforms =
      platforms
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    statuses = Enum.map(platforms, &platform_status/1)

    %{
      provider: Push.provider(),
      ready?: Enum.all?(statuses, &(&1.status == :ready)),
      platforms: statuses
    }
  end

  @spec platform_status(String.t()) :: platform_status()
  def platform_status(platform) when is_binary(platform) do
    case Push.ready_for?(platform) do
      :ok ->
        %{platform: platform, status: :ready, reason: nil, hint: nil}

      {:error, reason} ->
        %{platform: platform, status: :not_ready, reason: reason, hint: hint(platform, reason)}
    end
  end

  defp hint(_platform, :push_provider_unconfigured) do
    "Set DEV_IDE_PUSH_PROVIDER=native and configure APNs/FCM credentials for the target platforms."
  end

  defp hint(platform, :unsupported_platform) do
    "Unsupported push platform #{inspect(platform)}. Expected android/fcm or ios/apns."
  end

  defp hint(_platform, reason)
       when reason in [:no_project_id, :no_access_token_fun, :no_service_account] do
    "Configure Firebase with DEV_IDE_FCM_PROJECT_ID plus DEV_IDE_FCM_SERVICE_ACCOUNT_JSON, DEV_IDE_FCM_SERVICE_ACCOUNT_PATH, GOOGLE_APPLICATION_CREDENTIALS, or DEV_IDE_FCM_ACCESS_TOKEN."
  end

  defp hint(_platform, reason)
       when reason in [
              :no_team_id,
              :no_key_id,
              :no_topic,
              :no_private_key
            ] do
    "Configure APNs with DEV_IDE_APNS_TEAM_ID, DEV_IDE_APNS_KEY_ID, DEV_IDE_APNS_TOPIC, and DEV_IDE_APNS_PRIVATE_KEY or DEV_IDE_APNS_PRIVATE_KEY_PATH."
  end

  defp hint(platform, :invalid_private_key) when platform in ["android", "fcm"] do
    "Check the Firebase service account private_key."
  end

  defp hint(_platform, :invalid_private_key) do
    "Check the APNs private key."
  end

  defp hint(_platform, reason)
       when reason in [:invalid_service_account] do
    "Check the Firebase service account JSON. It must include project_id, client_email, and private_key."
  end

  defp hint(_platform, {:bad_service_account_json, _reason}) do
    "Check the Firebase service account JSON. It must decode to an object with project_id, client_email, and private_key."
  end

  defp hint(_platform, _reason) do
    "Check server push provider configuration."
  end
end
