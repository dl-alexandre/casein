defmodule Casein.Clock.Scheduler do
  @moduledoc false

  use GenServer

  @type timer :: %{
          due_ms: non_neg_integer(),
          seq: non_neg_integer(),
          dest: pid() | atom(),
          msg: term()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, %{now_ms: Keyword.get(opts, :now_ms, 0), seq: 0, timers: %{}}}
  end

  @impl true
  def handle_call(:now_ms, _from, state), do: {:reply, state.now_ms, state}

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{now_ms: 0, seq: 0, timers: %{}}}
  end

  def handle_call({:send_after, dest, msg, delay_ms}, _from, state) do
    ref = make_ref()
    seq = state.seq + 1

    timer = %{
      due_ms: state.now_ms + delay_ms,
      seq: seq,
      dest: dest,
      msg: msg
    }

    {:reply, ref, %{state | seq: seq, timers: Map.put(state.timers, ref, timer)}}
  end

  def handle_call({:cancel, ref}, _from, state) do
    case Map.pop(state.timers, ref) do
      {nil, _timers} ->
        {:reply, false, state}

      {%{due_ms: due_ms}, timers} ->
        {:reply, max(due_ms - state.now_ms, 0), %{state | timers: timers}}
    end
  end

  def handle_call(:peek, _from, state) do
    {:reply, peek_next(state), state}
  end

  def handle_call(:step, _from, state) do
    case take_next(state) do
      :empty ->
        {:reply, :empty, state}

      {:ok, info, next_state} ->
        send(info.dest, info.msg)
        {:reply, {:ok, info}, next_state}
    end
  end

  def handle_call({:advance_to, target}, _from, state) when target >= state.now_ms do
    {fired, next_state} = fire_due(state, target)
    {:reply, {:ok, fired}, %{next_state | now_ms: target}}
  end

  def handle_call({:advance_to, target}, _from, state) do
    {:reply, {:error, {:target_behind, state.now_ms, target}}, state}
  end

  defp fire_due(state, target) do
    state.timers
    |> Enum.filter(fn {_ref, timer} -> timer.due_ms <= target end)
    |> Enum.sort_by(fn {_ref, timer} -> {timer.due_ms, timer.seq} end)
    |> Enum.map_reduce(state, fn {ref, timer}, acc ->
      info = step_info(ref, timer)
      send(timer.dest, timer.msg)

      {info,
       %{
         acc
         | now_ms: timer.due_ms,
           timers: Map.delete(acc.timers, ref)
       }}
    end)
  end

  defp peek_next(state) do
    case earliest(state.timers) do
      nil -> :empty
      {ref, timer} -> {:ok, step_info(ref, timer)}
    end
  end

  defp take_next(state) do
    case earliest(state.timers) do
      nil ->
        :empty

      {ref, timer} ->
        {:ok, step_info(ref, timer),
         %{state | now_ms: timer.due_ms, timers: Map.delete(state.timers, ref)}}
    end
  end

  defp earliest(timers) when map_size(timers) == 0, do: nil

  defp earliest(timers) do
    Enum.min_by(timers, fn {_ref, timer} -> {timer.due_ms, timer.seq} end)
  end

  defp step_info(ref, timer) do
    %{ref: ref, due_ms: timer.due_ms, dest: timer.dest, msg: timer.msg, seq: timer.seq}
  end
end
