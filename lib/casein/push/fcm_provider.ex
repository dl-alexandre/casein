defmodule Casein.Push.FCMProvider do
  @moduledoc """
  `Casein.Push.Provider` for Firebase Cloud Messaging (HTTP v1). Sends a
  `Casein.Alerts` notification to one FCM registration token.

  Android currently registers FCM tokens. iOS currently registers APNs tokens,
  so production native mobile delivery should normally use
  `Casein.Push.NativeProvider` to route Android to this module and iOS to
  `Casein.Push.APNSProvider`.

  Enable with:

      config :casein, :push_provider, Casein.Push.FCMProvider
      config :casein, Casein.Push.FCMProvider,
        project_id: "my-firebase-project",
        # 0-arity fun or {m, f, a} returning {:ok, oauth_access_token}. The
        # built-in service-account minter is:
        # {Casein.Push.FCMToken, :access_token, []}
        access_token_fun: {MyApp.FCMToken, :access_token, []}

  The HTTP transport is injectable (`:http_client`, default
  `Casein.Push.FCM.ReqClient`) so it's testable without network or credentials —
  see `Casein.Push.FCM.HTTP`.
  """
  @behaviour Casein.Push.Provider

  require Logger

  @endpoint "https://fcm.googleapis.com/v1/projects"

  @impl true
  def push(token, platform, notification) when is_binary(token) do
    with :ok <- fcm_platform?(platform),
         {:ok, project_id} <- project_id(),
         {:ok, access_token} <- access_token() do
      send_message(token, notification, project_id, access_token)
    end
  end

  @impl true
  def configured_for?(platform) do
    with :ok <- fcm_platform?(platform) do
      configured?()
    end
  end

  @impl true
  def configured? do
    with {:ok, _project_id} <- project_id() do
      access_token_source_configured?()
    end
  end

  defp fcm_platform?(platform) do
    case platform |> to_string() |> String.downcase() do
      "android" -> :ok
      "fcm" -> :ok
      _other -> {:error, :unsupported_platform}
    end
  end

  defp access_token_source_configured? do
    case config()[:access_token_fun] do
      fun when is_function(fun, 0) ->
        :ok

      {Casein.Push.FCMToken, :access_token, []} ->
        Casein.Push.FCMToken.configured?()

      {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
        :ok

      _ ->
        {:error, :no_access_token_fun}
    end
  end

  defp send_message(token, notification, project_id, access_token) do
    url = "#{@endpoint}/#{project_id}/messages:send"

    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"content-type", "application/json"}
    ]

    case http_client().post(url, headers, message(token, notification)) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("FCM push rejected (#{status}): #{inspect(body)}")
        {:error, {:fcm_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # FCM HTTP v1 message envelope. `data` carries the deep-link the device uses to
  # open the right SessionDetailScreen.
  defp message(token, notification) do
    %{
      "message" => %{
        "token" => token,
        "notification" => %{
          "title" => notification[:title] || "Session alert",
          "body" => body_text(notification)
        },
        "data" => data_payload(notification),
        "android" => %{"priority" => "high"},
        "apns" => %{"headers" => %{"apns-priority" => "10"}}
      }
    }
  end

  defp data_payload(notification) do
    data =
      %{
        "workspace_id" => to_string(notification[:workspace_id]),
        "action" => to_string(notification[:action]),
        "deep_link" =>
          notification[:deep_link] || "casein://session/#{notification[:workspace_id]}"
      }
      |> maybe_put_string("session_id", notification[:session_id])
      |> maybe_put_string("card_id", notification[:card_id])
      |> maybe_put_string("card_type", notification[:card_type])
      |> maybe_put_string("origin_id", notification[:origin_id])
      |> maybe_put_string("origin_name", notification[:origin_name])
      |> maybe_put_json("locator_json", notification[:locator])

    Map.put(data, "mob_notification_json", notification_json(notification, data))
  end

  defp notification_json(notification, data) do
    Jason.encode!(%{
      "id" => notification[:card_id] || "push:#{notification[:workspace_id]}",
      "title" => notification[:title] || "Session alert",
      "body" => body_text(notification),
      "source" => "push",
      "data" => data
    })
  end

  defp body_text(notification) do
    case notification[:reason] do
      reason when is_binary(reason) and reason != "" -> reason
      _ -> "Tap to open the session."
    end
  end

  defp maybe_put_string(data, _key, nil), do: data
  defp maybe_put_string(data, key, value), do: Map.put(data, key, to_string(value))

  defp maybe_put_json(data, _key, nil), do: data
  defp maybe_put_json(data, key, value), do: Map.put(data, key, Jason.encode!(value))

  defp project_id do
    case config()[:project_id] || inferred_project_id() do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :no_project_id}
    end
  end

  defp inferred_project_id do
    case Casein.Push.FCMToken.project_id() do
      {:ok, project_id} -> project_id
      {:error, _reason} -> nil
    end
  end

  defp access_token do
    case config()[:access_token_fun] do
      fun when is_function(fun, 0) -> normalize_token(fun.())
      {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) -> normalize_token(apply(m, f, a))
      _ -> {:error, :no_access_token_fun}
    end
  end

  defp normalize_token({:ok, token}) when is_binary(token), do: {:ok, token}
  defp normalize_token(token) when is_binary(token), do: {:ok, token}
  defp normalize_token({:error, _} = err), do: err
  defp normalize_token(other), do: {:error, {:bad_access_token, other}}

  defp http_client, do: config()[:http_client] || Casein.Push.FCM.ReqClient

  defp config, do: Application.get_env(:casein, __MODULE__, [])
end
