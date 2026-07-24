defmodule Casein.Test.Eventually do
  @moduledoc """
  Shared deadline-based poller for tests.

  Replaces the per-file duplicate `await_*` / `eventually` / `wait_until`
  helpers that used `Process.sleep/1` for poll backoff. Callers pass a
  zero-arity fun that is retried until it returns a truthy value; between
  attempts this module waits with `receive … after`, never `Process.sleep`.
  """

  @default_timeout_ms 2_000
  @default_interval_ms 15

  @doc """
  Repeatedly call `fun/0` until it returns a truthy value.

  Options:

    * `:timeout_ms` — deadline from first call (default `#{@default_timeout_ms}`)
    * `:interval_ms` — receive-after backoff between attempts (default `#{@default_interval_ms}`)
    * `:message` — `ExUnit.AssertionError` message on timeout

  Returns the truthy result of `fun`. On timeout, raises
  `ExUnit.AssertionError` (same failure class as `flunk/1`).
  """
  def await(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    message =
      Keyword.get(opts, :message, "condition not met within #{timeout_ms}ms")

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(fun, deadline, interval_ms, message)
  end

  defp do_await(fun, deadline, interval_ms, message) do
    case fun.() do
      result when result not in [false, nil] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise ExUnit.AssertionError, message: message
        else
          receive do
          after
            interval_ms -> :ok
          end

          do_await(fun, deadline, interval_ms, message)
        end
    end
  end
end
