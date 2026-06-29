defmodule DevIDE.Push.FCM.HTTP do
  @moduledoc """
  HTTP seam for `DevIDE.Push.FCMProvider`. Lets tests inject a double instead of
  hitting `fcm.googleapis.com`. Default impl is `DevIDE.Push.FCM.ReqClient`.
  """

  @callback post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: map()) ::
              {:ok, %{status: non_neg_integer(), body: term()}} | {:error, term()}
end

defmodule DevIDE.Push.FCM.ReqClient do
  @moduledoc "Default `DevIDE.Push.FCM.HTTP` over Req."
  @behaviour DevIDE.Push.FCM.HTTP

  @impl true
  def post(url, headers, body) do
    case Req.post(url, headers: headers, json: body) do
      {:ok, %Req.Response{status: status, body: resp}} -> {:ok, %{status: status, body: resp}}
      {:error, reason} -> {:error, reason}
    end
  end
end
