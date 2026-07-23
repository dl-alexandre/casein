defmodule DevIDE.Push.APNSProvider do
  @moduledoc """
  `DevIDE.Push.Provider` for Apple Push Notification service.

  iOS currently registers a native APNs device token. That token is not an FCM
  registration token, so iOS delivery must use APNs directly unless the native
  app later adopts Firebase Messaging on iOS.
  """
  @behaviour DevIDE.Push.Provider

  require Logger

  @sandbox_endpoint "https://api.sandbox.push.apple.com"
  @production_endpoint "https://api.push.apple.com"

  @impl true
  def push(token, platform, notification) when is_binary(token) do
    with :ok <- ios_platform?(platform),
         {:ok, cfg} <- provider_config(),
         {:ok, jwt} <- jwt(cfg) do
      url = "#{endpoint(cfg)}/3/device/#{URI.encode(token)}"

      headers = [
        {"authorization", "bearer #{jwt}"},
        {"apns-topic", cfg.topic},
        {"apns-push-type", "alert"},
        {"apns-priority", "10"}
      ]

      case http_client().post(url, headers, payload(notification)) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.warning("APNs push rejected (#{status}): #{inspect(body)}")
          {:error, apns_error(status, body)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def configured_for?(platform) do
    with :ok <- ios_platform?(platform) do
      configured?()
    end
  end

  @impl true
  def configured? do
    case provider_config() do
      {:ok, _cfg} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ios_platform?(platform) do
    platform
    |> to_string()
    |> String.downcase()
    |> then(fn
      platform when platform in ["ios", "apns"] -> :ok
      _other -> {:error, :unsupported_platform}
    end)
  end

  defp provider_config do
    cfg = config()

    with {:ok, team_id} <- required(cfg, :team_id),
         {:ok, key_id} <- required(cfg, :key_id),
         {:ok, topic} <- required(cfg, :topic),
         {:ok, private_key} <- private_key(cfg) do
      {:ok,
       %{
         team_id: team_id,
         key_id: key_id,
         topic: topic,
         private_key: private_key,
         environment: Keyword.get(cfg, :environment, "sandbox")
       }}
    end
  end

  # `key` is always one of the fixed atoms passed by provider_config/0
  # (:team_id/:key_id/:topic/:private_key) — a closed, code-controlled set, never
  # user input, so the interpolated atom can't exhaust the atom table.
  # sobelow_skip ["DOS.BinToAtom"]
  defp required(cfg, key) do
    case Keyword.get(cfg, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :"no_#{key}"}
    end
  end

  # private_key_path is an operator-set config value (DEV_IDE_APNS_PRIVATE_KEY_PATH),
  # never request/user input — no traversal surface.
  # sobelow_skip ["Traversal.FileModule"]
  defp private_key(cfg) do
    cond do
      key = Keyword.get(cfg, :private_key) ->
        decode_private_key(key)

      path = Keyword.get(cfg, :private_key_path) ->
        with {:ok, pem} <- File.read(path), do: decode_private_key(pem)

      true ->
        {:error, :no_private_key}
    end
  end

  defp decode_private_key(pem) when is_binary(pem) do
    pem
    |> :public_key.pem_decode()
    |> List.first()
    |> case do
      nil -> {:error, :invalid_private_key}
      entry -> {:ok, :public_key.pem_entry_decode(entry)}
    end
  rescue
    _ -> {:error, :invalid_private_key}
  end

  defp jwt(%{team_id: team_id, key_id: key_id, private_key: private_key}) do
    now = now()

    header =
      %{"alg" => "ES256", "kid" => key_id}
      |> Jason.encode!()
      |> b64()

    claims =
      %{"iss" => team_id, "iat" => now}
      |> Jason.encode!()
      |> b64()

    signing_input = "#{header}.#{claims}"

    signature =
      signing_input
      |> :public_key.sign(:sha256, private_key)
      |> der_ecdsa_to_raw()
      |> b64()

    {:ok, "#{signing_input}.#{signature}"}
  rescue
    _ -> {:error, :invalid_private_key}
  end

  defp der_ecdsa_to_raw(<<0x30, seq_len, rest::binary>>) when byte_size(rest) == seq_len do
    <<0x02, r_len, r::binary-size(r_len), 0x02, s_len, s::binary-size(s_len)>> = rest
    pad_int(r) <> pad_int(s)
  end

  defp pad_int(int) do
    int = strip_leading_zeroes(int)

    cond do
      byte_size(int) == 32 -> int
      byte_size(int) < 32 -> :binary.copy(<<0>>, 32 - byte_size(int)) <> int
      true -> binary_part(int, byte_size(int) - 32, 32)
    end
  end

  defp strip_leading_zeroes(<<0, rest::binary>>), do: strip_leading_zeroes(rest)
  defp strip_leading_zeroes(<<>>), do: <<0>>
  defp strip_leading_zeroes(int), do: int

  defp payload(notification) do
    data_payload(notification)
    |> Map.merge(%{
      "aps" => %{
        "alert" => %{
          "title" => notification[:title] || "Session alert",
          "body" => body_text(notification)
        },
        "sound" => "default"
      }
    })
  end

  defp data_payload(notification) do
    %{
      "id" => notification[:card_id] || "push:#{notification[:workspace_id]}",
      "workspace_id" => to_string(notification[:workspace_id]),
      "action" => to_string(notification[:action]),
      "deep_link" => notification[:deep_link] || "devide://session/#{notification[:workspace_id]}"
    }
    |> maybe_put_string("session_id", notification[:session_id])
    |> maybe_put_string("card_id", notification[:card_id])
    |> maybe_put_string("card_type", notification[:card_type])
    |> maybe_put_string("origin_id", notification[:origin_id])
    |> maybe_put_string("origin_name", notification[:origin_name])
    |> maybe_put_map("locator", notification[:locator])
  end

  defp body_text(notification) do
    case notification[:reason] do
      reason when is_binary(reason) and reason != "" -> reason
      _ -> "Tap to open the session."
    end
  end

  defp maybe_put_string(data, _key, nil), do: data
  defp maybe_put_string(data, key, value), do: Map.put(data, key, to_string(value))

  defp maybe_put_map(data, _key, nil), do: data
  defp maybe_put_map(data, key, value) when is_map(value), do: Map.put(data, key, value)

  defp apns_error(status, body) when status in [400, 410] do
    case apns_reason(body) do
      reason when reason in ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"] ->
        {:invalid_token, {:apns_status, status, reason}}

      reason ->
        {:apns_status, status, reason}
    end
  end

  defp apns_error(status, body), do: {:apns_status, status, apns_reason(body)}

  defp apns_reason(%{"reason" => reason}), do: reason
  defp apns_reason(%{reason: reason}), do: reason

  # The live Req/Finch client returns the APNs error body as a raw JSON string
  # (APNs doesn't set an application/json content-type Req would auto-decode), so
  # decode it here — otherwise the reason-specific invalid-token classification
  # below never matches and we'd return the whole JSON blob as the "reason".
  defp apns_reason(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} -> reason
      _ -> body
    end
  end

  defp apns_reason(body), do: body

  defp endpoint(%{environment: env}) when env in ["prod", "production"],
    do: @production_endpoint

  defp endpoint(_cfg), do: @sandbox_endpoint

  defp b64(value), do: Base.url_encode64(value, padding: false)

  defp now do
    case config()[:now_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.system_time(:second)
    end
  end

  defp http_client, do: config()[:http_client] || DevIDE.Push.APNS.ReqClient
  defp config, do: Application.get_env(:dev_ide, __MODULE__, [])
end
