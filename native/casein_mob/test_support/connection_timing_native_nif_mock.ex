defmodule CaseinMob.ConnectionTimingNativeNIFMock do
  @moduledoc false

  @state_key {__MODULE__, :state}

  def configure(opts \\ []) do
    Process.put(@state_key, %{
      platform_result:
        Keyword.get(opts, :platform_result, {:ok, Keyword.get(opts, :platform, :unknown)}),
      subscriber: Keyword.get(opts, :subscriber),
      stage_log_result: Keyword.get(opts, :stage_log_result, :ok),
      generic_log_result: Keyword.get(opts, :generic_log_result, :ok)
    })

    :ok
  end

  def platform do
    state().platform_result
    |> resolve_result()
  end

  def log(level, line) do
    %{subscriber: subscriber, generic_log_result: generic_log_result} = state()

    if is_pid(subscriber) do
      send(subscriber, {:native_generic_log, level, line})
    end

    resolve_result(generic_log_result)
  end

  def log_mobile_feed_stage(
        generation,
        cycle,
        stage,
        duration_ms,
        elapsed_ms,
        outcome,
        reason_code
      ) do
    %{subscriber: subscriber, stage_log_result: stage_log_result} = state()

    if is_pid(subscriber) do
      send(
        subscriber,
        {:native_feed_stage, generation, cycle, stage, duration_ms, elapsed_ms, outcome,
         reason_code}
      )
    end

    resolve_result(stage_log_result)
  end

  defp state do
    Process.get(@state_key, %{
      platform_result: {:ok, :unknown},
      subscriber: nil,
      stage_log_result: :ok,
      generic_log_result: :ok
    })
  end

  defp resolve_result(:ok), do: :ok
  defp resolve_result({:ok, value}), do: value
  defp resolve_result({:nif_error, reason}), do: :erlang.nif_error(reason)
  defp resolve_result({:erlang_error, reason}), do: :erlang.error(reason)
  defp resolve_result({:exit, reason}), do: exit(reason)

  defp resolve_result({:raise_undefined_function, module, function, arity}) do
    raise UndefinedFunctionError, module: module, function: function, arity: arity
  end

  defp resolve_result({:undefined_function, module, function, args}) do
    apply(module, function, args)
  end
end
