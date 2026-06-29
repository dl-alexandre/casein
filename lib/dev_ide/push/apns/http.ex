defmodule DevIDE.Push.APNS.HTTP do
  @moduledoc """
  HTTP seam for `DevIDE.Push.APNSProvider`.

  APNs requires HTTP/2 in production. Req/Finch negotiates that in the default
  client; tests inject a stub through this behaviour.
  """

  @callback post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: map()) ::
              {:ok, %{status: non_neg_integer(), body: term()}} | {:error, term()}
end

defmodule DevIDE.Push.APNS.ReqClient do
  @moduledoc "Default `DevIDE.Push.APNS.HTTP` over Req."
  @behaviour DevIDE.Push.APNS.HTTP

  @impl true
  def post(url, headers, body) do
    case Req.post(url, headers: headers, json: body) do
      {:ok, %Req.Response{status: status, body: resp}} -> {:ok, %{status: status, body: resp}}
      {:error, reason} -> {:error, reason}
    end
  end
end
