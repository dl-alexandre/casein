defmodule Casein.Agents.JidoWorkcell do
  @moduledoc """
  Public Workcell API for Casein-owned headless Jido workers.

  A Workcell is one supervised cell per workspace and can admit several
  bounded workers. The existing Jido pod performs the typed action execution;
  this facade adds explicit Workcell identity, lifecycle events, Git scope
  binding, and a stable fallback contract for OpenCode/Claude.
  """

  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoWorkcell.{Cell, Events}
  alias Casein.Agents.JidoWorkcell.Limits

  @type state ::
          :requested
          | :queued
          | :provisioning
          | :ready
          | :active
          | :waiting
          | :completed
          | :failed
          | :cancelled
          | :draining
          | :stopped

  @spec workcell_id(String.t()) :: String.t()
  def workcell_id(workspace_id) when is_binary(workspace_id) do
    # Workcell IDs are Gate 0 scalar IDs. Workspace refs can contain path or
    # transport punctuation, so derive a stable lowercase-safe assignment ID
    # without exposing or reusing the external workspace spelling.
    digest =
      :crypto.hash(:sha256, workspace_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "workcell-" <> digest
  end

  @spec ensure(String.t(), keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def ensure(workspace_id, opts \\ []) when is_binary(workspace_id) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    cond do
      not is_map(opts) ->
        {:error, :invalid_argument}

      not Limits.workspace_allowed?(workspace_id) ->
        {:error, :workspace_not_allowed}

      true ->
        # One Workcell identity is derived from one workspace. Callers may not
        # manufacture a second cell for the same workspace by supplying a key.
        workcell_id = workcell_id(workspace_id)

        case Cell.whereis(workcell_id) do
          pid when is_pid(pid) ->
            {:ok, pid}

          nil ->
            case DynamicSupervisor.start_child(
                   Casein.Agents.JidoWorkcell.CellSupervisor,
                   {Cell, workspace_id: workspace_id, workcell_id: workcell_id}
                 ) do
              {:ok, pid} -> {:ok, pid}
              {:error, {:already_started, pid}} -> {:ok, pid}
              other -> other
            end
        end
    end
  end

  @spec admit(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def admit(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    if not Limits.workspace_allowed?(workspace_id) do
      {:error, :workspace_not_allowed}
    else
      do_admit(workspace_id, attrs)
    end
  end

  def admit(_workspace_id, _attrs), do: {:error, :invalid_argument}

  defp do_admit(workspace_id, attrs) do
    case JidoPod.select_runtime(workspace_id, attrs) do
      :jido ->
        with {:ok, pid} <- ensure(workspace_id, attrs) do
          Cell.admit(pid, attrs)
        end

      :opencode ->
        {:ok, fallback_receipt(workspace_id, fallback_reason(attrs), attrs)}
    end
  end

  @spec status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def status(workspace_id, worker_id) when is_binary(workspace_id) and is_binary(worker_id) do
    with {:ok, pid} <- fetch(workspace_id) do
      Cell.status(pid, worker_id)
    end
  end

  @spec list(String.t()) :: [map()]
  def list(workspace_id) when is_binary(workspace_id) do
    case fetch(workspace_id) do
      {:ok, pid} -> Cell.list(pid)
      {:error, :not_found} -> []
    end
  end

  @spec await(String.t(), String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(workspace_id, worker_id, timeout \\ 5_000)
      when is_binary(workspace_id) and is_binary(worker_id) do
    with {:ok, pid} <- fetch(workspace_id) do
      Cell.await(pid, worker_id, timeout)
    end
  end

  @spec cancel(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(workspace_id, worker_id) when is_binary(workspace_id) and is_binary(worker_id) do
    with {:ok, pid} <- fetch(workspace_id) do
      Cell.cancel(pid, worker_id)
    end
  end

  @spec drain(String.t()) :: {:ok, [map()]} | {:error, term()}
  def drain(workspace_id) when is_binary(workspace_id) do
    with {:ok, pid} <- fetch(workspace_id) do
      Cell.drain(pid)
    end
  end

  @spec snapshot(String.t()) :: map()
  def snapshot(workspace_id) when is_binary(workspace_id) do
    case fetch(workspace_id) do
      {:ok, pid} ->
        Cell.snapshot(pid)

      {:error, :not_found} ->
        %{workcell_id: workcell_id(workspace_id), state: :stopped, workers: 0}
    end
  end

  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(workspace_id) when is_binary(workspace_id) do
    workcell_id = workcell_id(workspace_id)

    case Cell.whereis(workcell_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(Casein.Agents.JidoWorkcell.CellSupervisor, pid)
    end
  end

  @spec subscribe(String.t()) :: :ok
  def subscribe(workcell_id) when is_binary(workcell_id), do: Events.subscribe(workcell_id)

  @spec fallback(String.t(), atom(), map()) :: map()
  def fallback(workspace_id, reason, attrs \\ %{}) when is_binary(workspace_id) do
    fallback_receipt(workspace_id, reason, attrs)
  end

  @spec fallback_for(map(), atom()) :: map()
  def fallback_for(prior, reason) when is_map(prior) do
    workspace_id = prior[:workspace_id] || prior["workspace_id"]
    fallback_receipt(workspace_id, reason, prior)
  end

  defp fetch(workspace_id) do
    case Cell.whereis(workcell_id(workspace_id)) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_found}
    end
  end

  defp fallback_receipt(workspace_id, reason, attrs) do
    runtime = get(attrs, :fallback_runtime) || get(attrs, :runtime_fallback) || :opencode

    %{
      runtime: normalize_fallback_runtime(runtime),
      fallback?: true,
      reason: reason,
      workspace_id: workspace_id,
      headless: false,
      pane_required?: true,
      next_tool: "worker_launch",
      next_arguments: %{
        workspace_id: workspace_id,
        runtime: Atom.to_string(normalize_fallback_runtime(runtime))
      },
      dry_run: truthy?(get(attrs, :dry_run)),
      message: "Jido is unavailable for this capability; use worker_launch for the fallback"
    }
  end

  defp fallback_reason(attrs) do
    case get(attrs, :runtime) do
      :opencode -> :explicit_opencode
      "opencode" -> :explicit_opencode
      _ -> :jido_disabled
    end
  end

  defp normalize_fallback_runtime(:claude), do: :claude
  defp normalize_fallback_runtime("claude"), do: :claude
  defp normalize_fallback_runtime(_), do: :opencode

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  defp truthy?(value), do: value in [true, "true", "1", 1]
end
