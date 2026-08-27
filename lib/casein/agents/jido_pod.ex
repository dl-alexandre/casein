defmodule Casein.Agents.JidoPod do
  @moduledoc """
  Headless workspace Jido pod: one coordinator per workspace, bounded workers.

  This is the #1014 first slice. It does not launch OpenCode or a tmux pane.
  Workers call bounded typed Jido actions: Casein Code actions for edits and
  verification, plus human-input and handoff reporting. They never use the
  filesystem or a shell.

  Feature flag: `config :casein, :jido_headless, true` or
  `CASEIN_JIDO_HEADLESS=1`. Per-workspace override via
  `:jido_headless_workspaces` / `CASEIN_JIDO_HEADLESS_WORKSPACES`. An admit
  with `runtime: :opencode` always stays on the legacy path; `runtime: :jido`
  requires the flag.
  """

  alias Casein.Agents.JidoPod.{Attempt, Fleet, Metrics, Pod}
  alias Casein.Agents.JidoRuntime

  @type admit_attrs :: %{
          required(:workspace_id) => String.t(),
          optional(:task_id) => String.t(),
          optional(:attempt_id) => String.t(),
          optional(:worktree_path) => String.t(),
          optional(:principal) => String.t(),
          optional(:actions) => [Attempt.action()],
          optional(:runtime) => :jido | :opencode,
          optional(:deadline_ms) => pos_integer(),
          optional(:action_timeout_ms) => pos_integer(),
          optional(:max_retries) => non_neg_integer()
        }

  @spec enabled?(String.t(), keyword() | map()) :: boolean()
  def enabled?(workspace_id, opts \\ [])

  def enabled?(workspace_id, opts) when is_binary(workspace_id) and is_list(opts) do
    enabled?(workspace_id, Map.new(opts))
  end

  def enabled?(workspace_id, opts) when is_binary(workspace_id) and is_map(opts) do
    case runtime_choice(workspace_id, opts) do
      :jido -> true
      :opencode -> false
    end
  end

  @spec select_runtime(String.t(), keyword() | map()) :: :jido | :opencode
  def select_runtime(workspace_id, opts \\ [])

  def select_runtime(workspace_id, opts) when is_binary(workspace_id) and is_list(opts) do
    select_runtime(workspace_id, Map.new(opts))
  end

  def select_runtime(workspace_id, opts) when is_binary(workspace_id) and is_map(opts) do
    runtime_choice(workspace_id, opts)
  end

  @spec admit(admit_attrs()) :: {:ok, map()} | {:error, term()}
  def admit(%{workspace_id: workspace_id} = attrs) when is_binary(workspace_id) do
    case runtime_choice(workspace_id, attrs) do
      :opencode ->
        Metrics.inc(:legacy_opencode)
        {:error, :legacy_opencode}

      :jido ->
        with {:ok, pid} <- ensure_pod(workspace_id) do
          Pod.admit(pid, attrs)
        end
    end
  end

  def admit(_), do: {:error, :invalid_workspace}

  @spec cancel(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(workspace_id, attempt_id)
      when is_binary(workspace_id) and is_binary(attempt_id) do
    with {:ok, pid} <- fetch_pod(workspace_id) do
      Pod.cancel(pid, attempt_id)
    end
  end

  @spec resume(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(workspace_id, attempt_id)
      when is_binary(workspace_id) and is_binary(attempt_id) do
    with {:ok, pid} <- fetch_pod(workspace_id) do
      Pod.resume(pid, attempt_id)
    end
  end

  @spec status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def status(workspace_id, attempt_id)
      when is_binary(workspace_id) and is_binary(attempt_id) do
    with {:ok, pid} <- fetch_pod(workspace_id) do
      Pod.status(pid, attempt_id)
    end
  end

  @spec list(String.t()) :: [map()]
  def list(workspace_id) when is_binary(workspace_id) do
    case fetch_pod(workspace_id) do
      {:ok, pid} -> Pod.list(pid)
      {:error, :not_found} -> []
    end
  end

  @spec await(String.t(), String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(workspace_id, attempt_id, timeout_ms \\ 5_000)
      when is_binary(workspace_id) and is_binary(attempt_id) do
    case status(workspace_id, attempt_id) do
      {:ok, %{state: state} = attempt} ->
        if Attempt.terminal?(state) do
          {:ok, attempt}
        else
          _ = Pod.subscribe(workspace_id)
          await_loop(workspace_id, attempt_id, timeout_ms)
        end

      other ->
        other
    end
  end

  @spec drain(String.t()) :: {:ok, [map()]} | {:error, term()}
  def drain(workspace_id) when is_binary(workspace_id) do
    with {:ok, pid} <- fetch_pod(workspace_id) do
      Pod.drain(pid)
    end
  end

  @spec subscribe(String.t()) :: :ok | {:error, :not_found}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    case fetch_pod(workspace_id) do
      {:ok, _pid} -> Pod.subscribe(workspace_id)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec stop_pod(String.t()) :: :ok | {:error, :not_found}
  def stop_pod(workspace_id) when is_binary(workspace_id) do
    case Pod.whereis(workspace_id) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(Casein.Agents.JidoPod.PodSupervisor, pid)
    end
  end

  @spec snapshot(String.t() | :fleet) :: map()
  def snapshot(:fleet) do
    Map.merge(Metrics.snapshot(), %{
      fleet: Fleet.snapshot(),
      budgets: Casein.Agents.JidoBudgets.snapshot()
    })
  end

  def snapshot(workspace_id) when is_binary(workspace_id) do
    pod =
      case fetch_pod(workspace_id) do
        {:ok, pid} -> Pod.snapshot(pid)
        {:error, :not_found} -> %{workspace_id: workspace_id, running: 0, queued: 0}
      end

    Map.merge(snapshot(:fleet), %{pod: pod})
  end

  @spec benchmark(keyword()) :: map()
  def benchmark(opts \\ []) do
    n = Keyword.get(opts, :n, 4)

    workspace_id =
      Keyword.get(opts, :workspace_id, "jido-bench-#{System.unique_integer([:positive])}")

    before = snapshot(:fleet)
    started = System.monotonic_time(:millisecond)

    attempts =
      Enum.map(1..n, fn _ ->
        {:ok, attempt} =
          admit(%{
            workspace_id: workspace_id,
            runtime: :jido,
            actions: Keyword.get(opts, :actions, [])
          })

        attempt
      end)

    results =
      Enum.map(attempts, fn attempt ->
        await(workspace_id, attempt.attempt_id, Keyword.get(opts, :timeout_ms, 5_000))
      end)

    elapsed = max(System.monotonic_time(:millisecond) - started, 1)
    after_snap = snapshot(:fleet)
    _ = stop_pod(workspace_id)

    %{
      n: n,
      elapsed_ms: elapsed,
      throughput_per_s: n * 1000 / elapsed,
      results: Enum.map(results, fn {:ok, attempt} -> attempt.state end),
      process_count_before: before.process_count,
      process_count_after: after_snap.process_count,
      memory_bytes_before: before.memory_bytes,
      memory_bytes_after: after_snap.memory_bytes,
      counts: after_snap.counts,
      opencode_baseline: after_snap.opencode_baseline
    }
  end

  @spec ensure_pod(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_pod(workspace_id, opts \\ []) when is_binary(workspace_id) and is_list(opts) do
    case Pod.whereis(workspace_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               Casein.Agents.JidoPod.PodSupervisor,
               {Pod, Keyword.put(opts, :workspace_id, workspace_id)}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  defp fetch_pod(workspace_id) do
    case Pod.whereis(workspace_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_found}
    end
  end

  defp await_loop(workspace_id, attempt_id, timeout_ms) do
    receive do
      {:jido_attempt, %{attempt_id: ^attempt_id, state: state} = attempt} ->
        if Attempt.terminal?(state),
          do: {:ok, attempt},
          else: await_loop(workspace_id, attempt_id, timeout_ms)
    after
      timeout_ms ->
        status(workspace_id, attempt_id)
        |> case do
          {:ok, %{state: state} = attempt} ->
            if Attempt.terminal?(state), do: {:ok, attempt}, else: {:error, :timeout}

          other ->
            other
        end
    end
  end

  defp runtime_choice(workspace_id, opts) do
    case requested_runtime(opts) do
      :opencode -> :opencode
      :jido -> jido_if_enabled(workspace_id)
      nil -> jido_if_enabled(workspace_id)
    end
  end

  defp requested_runtime(opts) do
    case Map.get(opts, :runtime) || Map.get(opts, "runtime") do
      :opencode -> :opencode
      "opencode" -> :opencode
      :jido -> :jido
      "jido" -> :jido
      _ -> nil
    end
  end

  defp jido_if_enabled(workspace_id) do
    if JidoRuntime.casein_enabled?() and JidoRuntime.profile().runtime == "jido" and
         (globally_enabled?() or workspace_enabled?(workspace_id)),
       do: :jido,
       else: :opencode
  end

  defp globally_enabled? do
    Application.get_env(:casein, :jido_headless, false) == true
  end

  defp workspace_enabled?(workspace_id) do
    case Application.get_env(:casein, :jido_headless_workspaces, %{}) do
      map when is_map(map) ->
        Map.get(map, workspace_id) == true

      list when is_list(list) ->
        workspace_id in list

      _ ->
        false
    end
  end
end
