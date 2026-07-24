defmodule Casein.Push.APNS.StubHTTP do
  @moduledoc """
  Test double for `Casein.Push.APNS.HTTP`.
  """
  @behaviour Casein.Push.APNS.HTTP

  @impl true
  def post(url, headers, body) do
    case Application.get_env(:casein, :apns_test_pid) do
      pid when is_pid(pid) -> send(pid, {:apns_request, url, headers, body})
      _ -> :ok
    end

    Application.get_env(:casein, :apns_stub_response, {:ok, %{status: 200, body: %{}}})
  end
end
