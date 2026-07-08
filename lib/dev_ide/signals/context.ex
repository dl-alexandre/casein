defmodule DevIDE.Signals.Context do
  @moduledoc """
  Process-scoped causality context for audit provenance.

  Thin wrapper over `Jido.Signal.TraceContext`: the trace_id doubles as the
  correlation id for an entire causal chain, and causation_id points at the
  audit event that directly caused the next one. The wrapper exists because
  `TraceContext.with_context/2` clears (rather than restores) the previous
  context on exit, which is unsafe in long-lived processes (LiveViews,
  GenServers) where scopes can nest.

  Entry points wrap their work in `with_new/1`; process boundaries hand off
  explicitly — capture `snapshot/0` in the client, re-install with
  `with_snapshot/2` inside the other process. `DevIDE.Audit.emit/1` stamps
  the ids into event metadata and calls `advance/1` after each recorded
  event so consecutive emissions form a linked causation chain.
  """

  alias Jido.Signal.Trace
  alias Jido.Signal.TraceContext

  @type t :: Trace.Context.t()

  @doc "Run `fun` under a fresh correlation context, restoring the prior one after."
  @spec with_new((-> result)) :: result when result: var
  def with_new(fun) when is_function(fun, 0) do
    scoped(Trace.new_root(), fun)
  end

  @doc "Run `fun` under a captured snapshot (nil snapshot: run bare)."
  @spec with_snapshot(t() | nil, (-> result)) :: result when result: var
  def with_snapshot(nil, fun) when is_function(fun, 0), do: fun.()
  def with_snapshot(%Trace.Context{} = ctx, fun) when is_function(fun, 0), do: scoped(ctx, fun)

  @default_task_supervisor DevIDE.TaskSupervisor

  @doc """
  Run `fun` in a supervised task, propagating the caller's context snapshot.

  Returns a `Task` suitable for `Task.yield/2` / `Task.await/2`. Uses
  `DevIDE.TaskSupervisor` by default; pass a supervisor to `async/2`.
  """
  @spec async((-> term())) :: Task.t()
  def async(fun) when is_function(fun, 0), do: async(@default_task_supervisor, fun)

  @spec async(Task.Supervisor.name(), (-> term())) :: Task.t()
  def async(supervisor, fun) when is_function(fun, 0) do
    snap = snapshot()

    Task.Supervisor.async_nolink(supervisor, fn ->
      with_snapshot(snap, fun)
    end)
  end

  @doc "Capture the current context for cross-process handoff."
  @spec snapshot() :: t() | nil
  def snapshot, do: TraceContext.current()

  @spec current() :: t() | nil
  def current, do: TraceContext.current()

  @doc "Point the context's causation at the event that was just recorded."
  @spec advance(String.t()) :: :ok
  def advance(event_id) when is_binary(event_id) do
    case TraceContext.current() do
      nil -> :ok
      ctx -> TraceContext.set(Trace.child_of(ctx, event_id))
    end
  end

  @doc """
  Stamp correlation/causation ids into the attrs `:metadata` map (string
  keys, only when absent). No-op without an active context.
  """
  @spec stamp(map()) :: map()
  def stamp(attrs) when is_map(attrs) do
    case TraceContext.current() do
      nil ->
        attrs

      ctx ->
        metadata =
          (Map.get(attrs, :metadata) || %{})
          |> Map.put_new("correlation_id", ctx.trace_id)
          |> put_new_present("causation_id", ctx.causation_id)

        Map.put(attrs, :metadata, metadata)
    end
  end

  defp scoped(ctx, fun) do
    prev = TraceContext.current()
    TraceContext.set(ctx)

    try do
      fun.()
    after
      restore(prev)
    end
  end

  defp restore(nil), do: TraceContext.clear()
  defp restore(prev), do: TraceContext.set(prev)

  defp put_new_present(map, _key, nil), do: map
  defp put_new_present(map, key, value), do: Map.put_new(map, key, value)
end
