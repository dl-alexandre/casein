defmodule CaseinMob.ConnectionTimingNativeNIFMock do
  @moduledoc false

  @state_key {__MODULE__, :state}

  def configure(opts \\ []) do
    Process.put(@state_key, %{
      platform_result:
        Keyword.get(opts, :platform_result, {:ok, Keyword.get(opts, :platform, :unknown)}),
      subscriber: Keyword.get(opts, :subscriber),
      log_result: Keyword.get(opts, :log_result, :ok)
    })

    :ok
  end

  def platform do
    state().platform_result
    |> resolve_result()
  end

  def log(level, line) do
    %{subscriber: subscriber, log_result: log_result} = state()

    if is_pid(subscriber) do
      send(subscriber, {:native_timing_log, level, line})
    end

    resolve_result(log_result)
  end

  defp state do
    Process.get(@state_key, %{
      platform_result: {:ok, :unknown},
      subscriber: nil,
      log_result: :ok
    })
  end

  defp resolve_result(:ok), do: :ok
  defp resolve_result({:ok, value}), do: value
  defp resolve_result({:nif_error, reason}), do: :erlang.nif_error(reason)
  defp resolve_result({:erlang_error, reason}), do: :erlang.error(reason)
  defp resolve_result({:exit, reason}), do: exit(reason)

  defp resolve_result({:undefined_function, module, function, args}) do
    apply(module, function, args)
  end
end
