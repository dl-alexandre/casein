defmodule DevIDE.Push.APNS.StubHTTP do
  @moduledoc """
  Test double for `DevIDE.Push.APNS.HTTP`.
  """
  @behaviour DevIDE.Push.APNS.HTTP

  @impl true
  def post(url, headers, body) do
    case Application.get_env(:dev_ide, :apns_test_pid) do
      pid when is_pid(pid) -> send(pid, {:apns_request, url, headers, body})
      _ -> :ok
    end

    Application.get_env(:dev_ide, :apns_stub_response, {:ok, %{status: 200, body: %{}}})
  end
end
