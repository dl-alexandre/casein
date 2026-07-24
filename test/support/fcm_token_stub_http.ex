defmodule Casein.Push.FCMToken.StubHTTP do
  @moduledoc """
  Test double for `Casein.Push.FCMToken.HTTP`.
  """
  @behaviour Casein.Push.FCMToken.HTTP

  @impl true
  def post_form(url, headers, body) do
    case Application.get_env(:casein, :fcm_token_test_pid) do
      pid when is_pid(pid) -> send(pid, {:fcm_token_request, url, headers, body})
      _ -> :ok
    end

    Application.get_env(
      :casein,
      :fcm_token_stub_response,
      {:ok, %{status: 200, body: %{"access_token" => "ya29.stub-token", "expires_in" => 3_600}}}
    )
  end
end
