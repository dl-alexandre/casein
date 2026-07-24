defmodule Casein.Push.TestProvider do
  @moduledoc """
  Test `Casein.Push.Provider` — forwards each push to the pid stored in
  `:dev_ide, :push_test_pid` as `{:pushed, token, platform, notification}` so
  tests can assert delivery without a real APNs/FCM backend.
  """
  @behaviour Casein.Push.Provider

  @impl true
  def push(token, platform, notification) do
    case Application.get_env(:dev_ide, :push_test_pid) do
      pid when is_pid(pid) -> send(pid, {:pushed, token, platform, notification})
      _ -> :ok
    end

    case Application.get_env(:dev_ide, :push_test_response, :ok) do
      fun when is_function(fun, 3) -> fun.(token, platform, notification)
      response -> response
    end
  end

  @impl true
  def configured_for?(_platform), do: :ok
end
