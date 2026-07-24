defmodule Casein.Push.APNS.HTTP do
  @moduledoc """
  HTTP seam for `Casein.Push.APNSProvider`.

  APNs **requires HTTP/2** — it closes any HTTP/1.1 connection mid-handshake
  (surfaces as `%Req.TransportError{reason: :closed}`). Req/Finch does *not*
  negotiate HTTP/2 by default, so the production client
  (`Casein.Push.APNS.ReqClient`) routes through a dedicated HTTP/2 Finch pool
  (`Casein.Push.APNS.Finch`, started in the supervision tree). Tests inject a
  stub through this behaviour and never touch the network.
  """

  @callback post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: map()) ::
              {:ok, %{status: non_neg_integer(), body: term()}} | {:error, term()}
end

defmodule Casein.Push.APNS.ReqClient do
  @moduledoc """
  Default `Casein.Push.APNS.HTTP` over Req, pinned to the HTTP/2 Finch pool
  `Casein.Push.APNS.Finch`.

  Finch establishes the HTTP/2 connection asynchronously, so the very first
  request after boot can lose a race and return `:pool_not_available`. We retry
  that specific error a few times with a short backoff; in steady state the
  long-lived connection is already warm and the first attempt succeeds.
  """
  @behaviour Casein.Push.APNS.HTTP

  # The HTTP/2 Finch pool this client routes through is started in the
  # supervision tree (`Casein.Supervision.PlatformServices`) so the connection
  # is warm before the first push.
  @finch Casein.Push.APNS.Finch
  @max_attempts 5
  @retry_sleep_ms 250

  @impl true
  def post(url, headers, body), do: post(url, headers, body, 1)

  defp post(url, headers, body, attempt) do
    case Req.post(url, headers: headers, json: body, finch: @finch) do
      {:ok, %Req.Response{status: status, body: resp}} ->
        {:ok, %{status: status, body: resp}}

      {:error, %Req.HTTPError{reason: :pool_not_available}} when attempt < @max_attempts ->
        Process.sleep(@retry_sleep_ms)
        post(url, headers, body, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
