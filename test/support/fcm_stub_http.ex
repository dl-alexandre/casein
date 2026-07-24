defmodule Casein.Push.FCM.StubHTTP do
  @moduledoc """
  Test double for `Casein.Push.FCM.HTTP`. Forwards each request to the pid in
  `:dev_ide, :fcm_test_pid` as `{:fcm_request, url, headers, body}` and returns
  the canned response in `:dev_ide, :fcm_stub_response` (default 200).
  """
  @behaviour Casein.Push.FCM.HTTP

  @impl true
  def post(url, headers, body) do
    case Application.get_env(:dev_ide, :fcm_test_pid) do
      pid when is_pid(pid) -> send(pid, {:fcm_request, url, headers, body})
      _ -> :ok
    end

    Application.get_env(:dev_ide, :fcm_stub_response, {:ok, %{status: 200, body: %{}}})
  end
end
