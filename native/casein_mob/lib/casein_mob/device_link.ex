defmodule CaseinMob.DeviceLink do
  @moduledoc """
  Normalizes pairing payloads and exchanges short-lived bootstrap tokens for
  persistent device credentials when the origin supports it.
  """

  @exchange_client_env :device_link_exchange_client

  alias CaseinMob.OriginIdentity

  @type pairing :: %{
          url: String.t(),
          token: String.t(),
          workspace_id: String.t(),
          origin_id: String.t(),
          display_name: String.t()
        }

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
    opts =
      [json: request, receive_timeout: 10_000]
      |> Keyword.merge(req_connect_options(url))

    case Req.post(url, opts) do
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
    if allowed_transport?(url) do
      do_exchange_or_fallback(url, legacy)
    else
      {:error, :insecure_transport}
    end
  end

  defp do_exchange_or_fallback(url, legacy) do
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
    Application.get_env(:casein_mob, @exchange_client_env, &__MODULE__.post_exchange/2)
  end

  defp req_connect_options(url) do
    if URI.parse(url).scheme == "https" do
      case bundled_cacertfile() do
        {:ok, path} -> [connect_options: [transport_opts: [cacertfile: path]]]
        :error -> []
      end
    else
      []
    end
  end

  defp bundled_cacertfile do
    [
      mobile_priv_path("castore/cacerts.pem"),
      app_priv_path("castore/cacerts.pem")
    ]
    |> Enum.find(&(&1 && File.regular?(&1)))
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  defp mobile_priv_path(relative_path) do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> nil
      beams_dir -> Path.join([beams_dir, "priv", relative_path])
    end
  end

  defp app_priv_path(relative_path) do
    case :code.priv_dir(:casein_mob) do
      priv_dir when is_list(priv_dir) -> Path.join([List.to_string(priv_dir), relative_path])
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  end

  defp legacy_pairing(payload) do
    url = first_text([value(payload, :url), nested_value(payload, [:origin, :base_url])])

    pairing = %{
      url: url,
      token: value(payload, :token),
      workspace_id:
        first_text([
          value(payload, :workspace_id),
          value(payload, :resource_id),
          first_resource_id(payload, "workspace")
        ]),
      origin_id:
        first_text([
          nested_value(payload, [:origin, :id]),
          value(payload, :origin_id)
        ]) || legacy_origin_id(url),
      display_name:
        first_text([
          nested_value(payload, [:origin, :display_name]),
          nested_value(payload, [:origin, :name]),
          value(payload, :display_name)
        ]) || origin_display_name(url)
    }

    if usable_pairing?(pairing) and allowed_transport?(pairing.url),
      do: {:ok, pairing},
      else: {:error, :invalid_payload}
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
    url = first_text([value(body, :url), nested_value(body, [:origin, :base_url])])

    pairing = %{
      url: url,
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
        ]),
      origin_id:
        first_text([
          nested_value(body, [:origin, :id]),
          value(body, :origin_id)
        ]) || legacy_origin_id(url),
      display_name:
        first_text([
          nested_value(body, [:origin, :display_name]),
          nested_value(body, [:origin, :name]),
          value(body, :display_name)
        ]) || origin_display_name(url)
    }

    if usable_pairing?(pairing) and allowed_transport?(pairing.url),
      do: {:ok, pairing},
      else: {:error, :invalid_response}
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

  defp legacy_origin_id(url) when is_binary(url), do: OriginIdentity.legacy_id(url)
  defp legacy_origin_id(_url), do: nil

  defp origin_display_name(url) when is_binary(url), do: OriginIdentity.display_name(url)
  defp origin_display_name(_url), do: nil

  defp usable_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp allowed_transport?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        true

      %URI{scheme: "http", host: host} when is_binary(host) ->
        local_host?(String.downcase(host))

      _ ->
        false
    end
  end

  defp allowed_transport?(_url), do: false

  defp local_host?(host) when host in ["localhost", "127.0.0.1", "::1"], do: true
  defp local_host?(host), do: String.ends_with?(host, ".local") or private_ipv4?(host)

  defp private_ipv4?(host) do
    case host |> String.split(".") |> Enum.map(&Integer.parse/1) do
      [{10, ""}, {b, ""}, {c, ""}, {d, ""}] ->
        valid_octets?([10, b, c, d])

      [{172, ""}, {b, ""}, {c, ""}, {d, ""}] when b in 16..31 ->
        valid_octets?([172, b, c, d])

      [{192, ""}, {168, ""}, {c, ""}, {d, ""}] ->
        valid_octets?([192, 168, c, d])

      _ ->
        false
    end
  end

  defp valid_octets?(octets), do: Enum.all?(octets, &(&1 in 0..255))

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
