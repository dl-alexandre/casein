defmodule DevIDE.Push.FCMToken.HTTP do
  @moduledoc """
  HTTP seam for minting short-lived Google OAuth tokens from a service account.
  """

  @callback post_form(
              url :: String.t(),
              headers :: [{String.t(), String.t()}],
              body :: String.t()
            ) ::
              {:ok, %{status: non_neg_integer(), body: term()}} | {:error, term()}
end

defmodule DevIDE.Push.FCMToken.ReqClient do
  @moduledoc "Default `DevIDE.Push.FCMToken.HTTP` over Req."
  @behaviour DevIDE.Push.FCMToken.HTTP

  @impl true
  def post_form(url, headers, body) do
    case Req.post(url, headers: headers, body: body) do
      {:ok, %Req.Response{status: status, body: resp}} -> {:ok, %{status: status, body: resp}}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule DevIDE.Push.FCMToken do
  @moduledoc """
  Mints Firebase Cloud Messaging OAuth access tokens from Google service-account
  credentials.

  `DevIDE.Push.FCMProvider` needs a short-lived bearer token for FCM HTTP v1.
  This module implements Google's JWT bearer flow without adding a credential
  dependency:

      config :dev_ide, DevIDE.Push.FCMProvider,
        access_token_fun: {DevIDE.Push.FCMToken, :access_token, []}

      config :dev_ide, DevIDE.Push.FCMToken,
        service_account_path: "/run/secrets/firebase-service-account.json"

  Runtime config also supports:

    * `DEV_IDE_FCM_ACCESS_TOKEN` — direct pre-minted token, useful for smoke
      tests.
    * `DEV_IDE_FCM_SERVICE_ACCOUNT_JSON` — raw service-account JSON.
    * `DEV_IDE_FCM_SERVICE_ACCOUNT_PATH` or `GOOGLE_APPLICATION_CREDENTIALS` —
      path to service-account JSON.
  """

  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @default_token_uri "https://oauth2.googleapis.com/token"
  @grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @cache_key {__MODULE__, :access_token}

  @spec access_token() :: {:ok, String.t()} | {:error, term()}
  def access_token do
    cond do
      token = direct_access_token() ->
        {:ok, token}

      cache_enabled?() ->
        case cached_token() do
          {:ok, token} -> {:ok, token}
          :miss -> mint_and_cache()
        end

      true ->
        mint_access_token()
    end
  end

  @spec project_id() :: {:ok, String.t()} | {:error, term()}
  def project_id do
    case service_account() do
      {:ok, %{"project_id" => project_id}} when is_binary(project_id) and project_id != "" ->
        {:ok, project_id}

      {:ok, _account} ->
        {:error, :no_project_id}

      {:error, _reason} = error ->
        error
    end
  end

  @spec configured?() :: :ok | {:error, term()}
  def configured? do
    cond do
      direct_access_token() ->
        :ok

      true ->
        with {:ok, account} <- service_account(),
             {:ok, _key} <- private_key(account) do
          :ok
        end
    end
  end

  @spec clear_cache() :: :ok
  def clear_cache do
    try do
      :persistent_term.erase(@cache_key)
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  defp mint_and_cache do
    with {:ok, token, expires_in} <- mint_access_token_with_expiry() do
      expires_at_ms = now_ms() + max(expires_in - 60, 0) * 1_000
      :persistent_term.put(@cache_key, {token, expires_at_ms})
      {:ok, token}
    end
  end

  defp cached_token do
    now = now_ms()

    case :persistent_term.get(@cache_key, nil) do
      {token, expires_at_ms} when is_binary(token) and expires_at_ms > now ->
        {:ok, token}

      _ ->
        :miss
    end
  end

  defp mint_access_token do
    case mint_access_token_with_expiry() do
      {:ok, token, _expires_in} -> {:ok, token}
      {:error, _reason} = error -> error
    end
  end

  defp mint_access_token_with_expiry do
    with {:ok, account} <- service_account(),
         {:ok, assertion} <- assertion(account) do
      request_token(token_uri(account), assertion)
    end
  end

  defp assertion(account) do
    with {:ok, key} <- private_key(account) do
      token_uri = token_uri(account)
      now = now_seconds()

      header = %{"alg" => "RS256", "typ" => "JWT"}

      claims = %{
        "iss" => account["client_email"],
        "sub" => account["client_email"],
        "scope" => @scope,
        "aud" => token_uri,
        "iat" => now,
        "exp" => now + 3_600
      }

      signing_input = jwt_segment(header) <> "." <> jwt_segment(claims)
      signature = :public_key.sign(signing_input, :sha256, key)
      {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}
    end
  end

  defp private_key(%{"client_email" => email, "private_key" => pem})
       when is_binary(email) and email != "" and is_binary(pem) and pem != "" do
    case :public_key.pem_decode(pem) do
      [entry | _rest] ->
        {:ok, :public_key.pem_entry_decode(entry)}

      [] ->
        {:error, :invalid_private_key}
    end
  rescue
    _ -> {:error, :invalid_private_key}
  end

  defp private_key(_account), do: {:error, :invalid_service_account}

  defp request_token(token_uri, assertion) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]
    body = URI.encode_query(%{"grant_type" => @grant_type, "assertion" => assertion})

    case http_client().post_form(token_uri, headers, body) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_token_body(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_endpoint_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_token_body(%{"access_token" => token} = body) when is_binary(token) do
    {:ok, token, expires_in(body)}
  end

  defp parse_token_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_token_body(decoded)
      {:error, reason} -> {:error, {:bad_token_response, reason}}
    end
  end

  defp parse_token_body(_body), do: {:error, :missing_access_token}

  defp expires_in(%{"expires_in" => seconds}) when is_integer(seconds), do: seconds

  defp expires_in(%{"expires_in" => seconds}) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {value, ""} -> value
      _ -> 3_600
    end
  end

  defp expires_in(_body), do: 3_600

  # The service-account path comes from operator config/env
  # (DEV_IDE_FCM_SERVICE_ACCOUNT_PATH / GOOGLE_APPLICATION_CREDENTIALS), never
  # request/user input — no traversal surface.
  # sobelow_skip ["Traversal.FileModule"]
  defp service_account do
    cond do
      account = config()[:service_account] ->
        normalize_service_account(account)

      json = configured_service_account_json() ->
        decode_service_account_json(json)

      path = configured_service_account_path() ->
        with {:ok, json} <- File.read(path), do: decode_service_account_json(json)

      true ->
        {:error, :no_service_account}
    end
  end

  defp normalize_service_account(account) when is_map(account) do
    account =
      account
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    {:ok, account}
  end

  defp normalize_service_account(_account), do: {:error, :invalid_service_account}

  defp decode_service_account_json(json) do
    case Jason.decode(json) do
      {:ok, account} when is_map(account) -> normalize_service_account(account)
      {:ok, _other} -> {:error, :invalid_service_account}
      {:error, reason} -> {:error, {:bad_service_account_json, reason}}
    end
  end

  defp token_uri(account) do
    config()[:token_uri] || account["token_uri"] || @default_token_uri
  end

  defp jwt_segment(term) do
    term
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp direct_access_token do
    case config()[:access_token] || env("DEV_IDE_FCM_ACCESS_TOKEN") do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp configured_service_account_json do
    config()[:service_account_json] || env("DEV_IDE_FCM_SERVICE_ACCOUNT_JSON")
  end

  defp configured_service_account_path do
    config()[:service_account_path] ||
      env("DEV_IDE_FCM_SERVICE_ACCOUNT_PATH") ||
      env("GOOGLE_APPLICATION_CREDENTIALS")
  end

  defp cache_enabled?, do: Keyword.get(config(), :cache, true)

  defp http_client, do: config()[:http_client] || DevIDE.Push.FCMToken.ReqClient

  defp now_seconds do
    case config()[:now_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.system_time(:second)
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp config, do: Application.get_env(:dev_ide, __MODULE__, [])
end
