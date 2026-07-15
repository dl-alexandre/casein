defmodule DevIDE.Codex.RuntimeSupervisor do
  @moduledoc """
  Dynamic supervisor for isolated Codex runtimes.

  One runtime owns one Codex home/worktree/security context and may host
  multiple Codex threads. Starting this supervisor never launches Codex by
  itself; runtimes are created explicitly with `start_runtime/1`.
  """

  use DynamicSupervisor

  alias DevIDE.Codex.Runtime

  @registry DevIDE.Codex.Registry

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_runtime(keyword()) :: DynamicSupervisor.on_start_child()
  def start_runtime(opts) do
    runtime_id = Keyword.fetch!(opts, :runtime_id)
    opts = Keyword.put(opts, :name, Runtime.component_via(runtime_id, :runtime))
    DynamicSupervisor.start_child(__MODULE__, {Runtime, opts})
  end

  @spec stop_runtime(String.t()) :: :ok | {:error, :not_found}
  def stop_runtime(runtime_id) when is_binary(runtime_id) do
    case whereis(runtime_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(runtime_id) when is_binary(runtime_id) do
    case Registry.lookup(@registry, {:runtime, runtime_id}) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @spec via(String.t()) :: {:via, Registry, {module(), term()}}
  def via(runtime_id) when is_binary(runtime_id),
    do: Runtime.component_via(runtime_id, :runtime)
end
