defmodule DevideMob.DeviceLink do
  @moduledoc """
  Normalizes pairing payloads and exchanges short-lived bootstrap tokens for
  persistent device credentials when the origin supports it.
  """

  @exchange_client_env :device_link_exchange_client

  @type pairing :: %{url: String.t(), token: String.t(), workspace_id: String.t()}

  @doc """
  Return the credential the session client should store.

  New payloads include `token_exchange_url`; old payloads only include
  `{url, token, workspace_id}` and continue through the legacy path.
  """
  @spec pair(map()) :: {:ok, pairing()} | {:error, atom()}
  def pair(payload) when is_map(payload) do
    with {:ok, legacy} <- legacy_pairing(payload) do
      case exchange_url(payload) do
        nil -> {:ok, legacy}
        url -> exchange_or_fallback(url, legacy)
      end
    end
  end

  def pair(_payload), do: {:error, :invalid_payload}

  @doc false
  def post_exchange(url, request) when is_binary(url) and is_map(request) do
    case Req.post(url, json: request, receive_timeout: 10_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        normalize_exchange_response(body)

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} when status in [401, 403, 422] ->
        {:error, :rejected}

      {:ok, _response} ->
        {:error, :unavailable}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  defp exchange_or_fallback(url, legacy) do
    case exchange_client().(url, exchange_request(legacy)) do
      {:ok, pairing} ->
        {:ok, pairing}

      {:error, reason} when reason in [:not_found, :unavailable, :request_failed] ->
        {:ok, legacy}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exchange_client do
    Application.get_env(:devide_mob, @exchange_client_env, &__MODULE__.post_exchange/2)
  end

  defp legacy_pairing(payload) do
    pairing = %{
      url: first_text([value(payload, :url), nested_value(payload, [:origin, :base_url])]),
      token: value(payload, :token),
      workspace_id:
        first_text([
          value(payload, :workspace_id),
          value(payload, :resource_id),
          first_resource_id(payload, "workspace")
        ])
    }

    if usable_pairing?(pairing), do: {:ok, pairing}, else: {:error, :invalid_payload}
  end

  defp exchange_request(legacy) do
    %{
      token: legacy.token,
      device_name: device_name(),
      platform: platform()
    }
  end

  defp normalize_exchange_response(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body), do: normalize_exchange_response(decoded)
  end

  defp normalize_exchange_response(body) when is_map(body) do
    pairing = %{
      url: first_text([value(body, :url), nested_value(body, [:origin, :base_url])]),
      token:
        first_text([
          nested_value(body, [:credential, :token]),
          value(body, :token)
        ]),
      workspace_id:
        first_text([
          value(body, :workspace_id),
          value(body, :resource_id),
          first_resource_id(body, "workspace")
        ])
    }

    if usable_pairing?(pairing), do: {:ok, pairing}, else: {:error, :invalid_response}
  end

  defp normalize_exchange_response(_body), do: {:error, :invalid_response}

  defp exchange_url(payload) do
    first_text([
      value(payload, :token_exchange_url),
      nested_value(payload, [:origin, :token_exchange_url])
    ])
  end

  defp first_resource_id(payload, kind) do
    payload
    |> value(:resources)
    |> case do
      resources when is_list(resources) ->
        resources
        |> Enum.find(fn resource -> value(resource, :kind) == kind end)
        |> case do
          nil -> nil
          resource -> value(resource, :id)
        end

      _ ->
        nil
    end
  end

  defp nested_value(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case value(acc, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil

  defp first_text(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end)
  end

  defp usable_pairing?(%{url: url, token: token, workspace_id: workspace_id}) do
    usable_text?(url) and usable_text?(token) and usable_text?(workspace_id)
  end

  defp usable_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp device_name do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      _ -> "mobile-device"
    end
  end

  defp platform do
    case :mob_nif.platform() do
      platform when platform in [:android, :ios] -> Atom.to_string(platform)
      _ -> "mobile"
    end
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> "mobile"
  end
end
