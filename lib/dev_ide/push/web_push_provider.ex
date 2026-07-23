defmodule DevIDE.Push.WebPushProvider do
  @moduledoc """
  `DevIDE.Push.Provider` for browser Web Push (RFC 8030/8291/8292), used by the
  installed PWA so a phone gets an "agent needs you" notification while the app
  is backgrounded or closed.

  Encrypts the payload for the stored subscription (`DevIDE.Push.WebPush.Encryption`,
  verified against the RFC 8291 vector), signs a VAPID header
  (`DevIDE.Push.WebPush.Vapid`), and POSTs to the endpoint via `Req`.

  Inert until VAPID keys are configured (`config :dev_ide, __MODULE__, …` from
  `DEV_IDE_VAPID_*`); `configured?/0` reports `{:error, :push_provider_unconfigured}`
  otherwise, so `DevIDE.Push.ready_for?/1` gates delivery exactly like the other
  providers.
  """
  @behaviour DevIDE.Push.Provider

  alias DevIDE.Push
  alias DevIDE.Push.WebPush.{Encryption, Vapid}

  # 4 weeks — the push service caches until the device reconnects.
  @ttl_seconds 4 * 7 * 24 * 60 * 60

  @impl true
  def push(token, "web", notification) when is_binary(token) do
    with {:ok, cfg} <- config(),
         {:ok, subscription} <- Push.web_subscription(token),
         {:ok, endpoint, ua_public, auth} <- decode_subscription(subscription) do
      deliver(endpoint, ua_public, auth, notification, cfg)
    end
  end

  def push(_token, platform, _notification), do: {:error, {:unsupported_platform, platform}}

  @impl true
  def configured?() do
    case config() do
      {:ok, _cfg} -> :ok
      error -> error
    end
  end

  @impl true
  def configured_for?("web"), do: configured?()
  def configured_for?(platform), do: {:error, {:unsupported_platform, platform}}

  defp deliver(endpoint, ua_public, auth, notification, cfg) do
    body = notification |> payload() |> Jason.encode!() |> Encryption.encrypt(ua_public, auth)

    headers = [
      {"authorization", Vapid.authorization(endpoint, cfg)},
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"ttl", Integer.to_string(@ttl_seconds)}
    ]

    case Req.post(endpoint, headers: headers, body: body, decode_body: false, retry: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} when status in [404, 410] ->
        {:error, :subscription_gone}

      {:ok, %{status: status}} ->
        {:error, {:web_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Web Push has no title/body fields of its own — the service-worker `push`
  # handler reads this JSON and calls showNotification.
  defp payload(notification) do
    %{
      "title" => notification[:title] || "DevIDE",
      "body" => notification[:reason] || notification[:body] || "An agent needs you.",
      "url" => web_url(notification),
      "tag" => tag(notification),
      "workspace_id" => to_string(notification[:workspace_id] || ""),
      "notification_id" => notification[:notification_id]
    }
  end

  # Prefer an http(s) deep link; a native devide:// scheme can't open in a
  # browser, so fall back to the app root (the attention strip shows which agent).
  defp web_url(notification) do
    case notification[:deep_link] || notification[:url] do
      "http" <> _ = url -> url
      _ -> "/"
    end
  end

  defp tag(%{workspace_id: wid}) when is_binary(wid) and wid != "", do: "ws:#{wid}"
  defp tag(_), do: "devide"

  defp decode_subscription(%{"endpoint" => endpoint, "keys" => %{"p256dh" => p, "auth" => a}})
       when is_binary(endpoint) do
    with {:ok, ua_public} <- b64_decode(p),
         {:ok, auth} <- b64_decode(a) do
      {:ok, endpoint, ua_public, auth}
    end
  end

  defp decode_subscription(_), do: {:error, :invalid_subscription}

  # Browsers hand out unpadded base64url; be liberal.
  defp b64_decode(s) when is_binary(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_subscription}
    end
  end

  defp config do
    case Application.get_env(:dev_ide, __MODULE__) do
      %{public_key: pub, private_key: priv, subject: subject} = cfg
      when is_binary(pub) and is_binary(priv) and is_binary(subject) ->
        {:ok, cfg}

      _ ->
        {:error, :push_provider_unconfigured}
    end
  end
end
