defmodule Casein.Clock do
  @moduledoc """
  Prototype virtual clock and `send_after` scheduler (#897).

  Default (no `Casein.Clock.Scheduler` running) is real
  `System.monotonic_time/1` + `Process.send_after/3` — zero production
  behaviour change. Starting the scheduler switches every `send_after/3`
  through this module onto a logical timeline that only advances when
  `step/0` or `advance_to/1` runs.

  This is a feasibility probe, not a DST runtime. See
  `docs/prototypes/clock-step-determinism.md`.
  """

  alias Casein.Clock.Scheduler

  @type timer_ref :: reference()
  @type step_info :: %{
          ref: timer_ref(),
          due_ms: non_neg_integer(),
          dest: pid() | atom(),
          msg: term(),
          seq: non_neg_integer()
        }

  @spec virtual?() :: boolean()
  def virtual?, do: Process.whereis(Scheduler) != nil

  @spec start_virtual(keyword()) :: GenServer.on_start()
  def start_virtual(opts \\ []), do: Scheduler.start_link(opts)

  @spec reset() :: :ok
  def reset do
    case Process.whereis(Scheduler) do
      nil -> :ok
      pid -> GenServer.call(pid, :reset)
    end
  end

  @spec stop_virtual() :: :ok
  def stop_virtual do
    case Process.whereis(Scheduler) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid)
        :ok
    end
  end

  @spec now_ms() :: integer()
  def now_ms do
    case Process.whereis(Scheduler) do
      nil -> System.monotonic_time(:millisecond)
      pid -> GenServer.call(pid, :now_ms)
    end
  end

  @spec send_after(pid() | atom(), term(), non_neg_integer()) :: timer_ref()
  def send_after(dest, msg, delay_ms)
      when (is_pid(dest) or is_atom(dest)) and is_integer(delay_ms) and delay_ms >= 0 do
    case Process.whereis(Scheduler) do
      nil -> Process.send_after(dest, msg, delay_ms)
      pid -> GenServer.call(pid, {:send_after, dest, msg, delay_ms})
    end
  end

  @spec cancel_timer(timer_ref()) :: non_neg_integer() | false
  def cancel_timer(ref) when is_reference(ref) do
    case Process.whereis(Scheduler) do
      nil -> Process.cancel_timer(ref)
      pid -> GenServer.call(pid, {:cancel, ref})
    end
  end

  @spec peek() :: :empty | {:ok, step_info()}
  def peek do
    case Process.whereis(Scheduler) do
      nil -> :empty
      pid -> GenServer.call(pid, :peek)
    end
  end

  @spec step() :: :empty | {:ok, step_info()}
  def step do
    case Process.whereis(Scheduler) do
      nil -> :empty
      pid -> GenServer.call(pid, :step)
    end
  end

  @spec advance_to(non_neg_integer()) ::
          {:ok, [step_info()]} | {:error, :not_virtual | {:target_behind, integer(), integer()}}
  def advance_to(ms) when is_integer(ms) and ms >= 0 do
    case Process.whereis(Scheduler) do
      nil -> {:error, :not_virtual}
      pid -> GenServer.call(pid, {:advance_to, ms})
    end
  end

  @doc """
  Barrier that waits for `dest` to finish already-queued regular messages.

  Uses a normal `GenServer.call/3`, not `:sys.get_state/1`. Selective receive
  on `{system, _, _}` can skip past pending timer messages and report a
  pre-timer snapshot — that barrier is itself a determinism bug.
  """
  @spec sync(pid() | atom()) :: :ok
  def sync(dest) do
    _ = GenServer.call(dest, :clock_sync)
    :ok
  catch
    :exit, _ -> :ok
  end
end
