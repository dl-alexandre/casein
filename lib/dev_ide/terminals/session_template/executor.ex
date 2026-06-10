defmodule DevIDE.Terminals.SessionTemplate.Executor do
  @moduledoc """
  Execution boundary for session templates.

  M2.0 only supports dry-runs. Real tmux execution will be added behind this
  module so callers do not need to know whether a template is being planned or
  applied.
  """

  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.SessionTemplate.Planner
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology

  @spec plan(String.t() | SessionTemplate.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def plan(template_or_id, opts \\ []), do: Planner.plan(template_or_id, opts)

  @spec dry_run(String.t() | SessionTemplate.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def dry_run(template_or_id, opts \\ []), do: Planner.dry_run(template_or_id, opts)

  @spec execute(String.t(), String.t() | SessionTemplate.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute(session, template_or_id, opts \\ []) when is_binary(session) do
    with {:ok, dry_run} <- dry_run(template_or_id, opts) do
      execute_steps(session, dry_run, opts)
    end
  end

  defp execute_steps(session, dry_run, opts) do
    state = %{
      session: session,
      tmux: Keyword.get(opts, :tmux, Tmux),
      workspace_root: Keyword.get(opts, :workspace_root),
      refs: %{},
      executed_steps: []
    }

    dry_run.steps
    |> Enum.reduce_while({:ok, state}, fn step, {:ok, state} ->
      case execute_step(step, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, {reason, step, execution_summary(dry_run, state)}}}
      end
    end)
    |> case do
      {:ok, state} ->
        {:ok,
         dry_run
         |> Map.take([:template, :step_count])
         |> Map.merge(%{
           executed_steps: Enum.reverse(state.executed_steps),
           refs: state.refs
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_step(%{action: "new_window"} = step, state) do
    with {:ok, cwd} <- resolve_cwd(get_in(step, [:params, :cwd]), state.workspace_root),
         opts <- compact_opts(name: get_in(step, [:params, :name]), cwd: cwd),
         {:ok, window_id} <- state.tmux.new_window(state.session, opts),
         {:ok, root_pane_id} <- active_pane_for_window(state, window_id) do
      state
      |> put_ref(step.ref, window_id)
      |> put_ref(root_ref(step.ref), root_pane_id)
      |> record_step(step, %{window_id: window_id, root_pane_id: root_pane_id})
      |> ok()
    end
  end

  defp execute_step(%{action: "split_pane"} = step, state) do
    with {:ok, target_pane_id} <- resolve_ref(state, step.target_ref),
         {:ok, cwd} <- resolve_cwd(get_in(step, [:params, :cwd]), state.workspace_root),
         opts <- compact_opts(cwd: cwd),
         {:ok, pane_id} <-
           state.tmux.split_pane(state.session, target_pane_id, step.params.direction, opts) do
      state
      |> put_ref(step.ref, pane_id)
      |> record_step(step, %{pane_id: pane_id, target_pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_step(%{action: "send_command"} = step, state) do
    with {:ok, target_pane_id} <- resolve_ref(state, step.target_ref),
         :ok <-
           state.tmux.send_command(state.session, step.params.command, target: target_pane_id) do
      state
      |> record_step(step, %{target_pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_step(%{action: "select_pane"} = step, state) do
    with {:ok, target_pane_id} <- resolve_ref(state, step.target_ref),
         :ok <- state.tmux.select_pane(state.session, target_pane_id) do
      state
      |> record_step(step, %{pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_step(step, _state), do: {:error, {:unsupported_step, step.action}}

  defp active_pane_for_window(state, window_id) do
    topology = TmuxTopology.snapshot(state.session, tmux: state.tmux)

    topology.windows
    |> Enum.find(&(&1.id == window_id))
    |> case do
      %{pane_list: [%{id: pane_id} | _]} -> {:ok, pane_id}
      _ -> {:error, :root_pane_not_found}
    end
  end

  defp root_ref("window:" <> window_id), do: "pane:" <> window_id <> ":root"
  defp root_ref(ref), do: ref <> ":root"

  defp put_ref(state, ref, value), do: %{state | refs: Map.put(state.refs, ref, value)}

  defp resolve_ref(%{refs: refs}, ref) do
    case Map.fetch(refs, ref) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unresolved_ref, ref}}
    end
  end

  defp record_step(state, step, result) do
    executed_step =
      step
      |> Map.take([:index, :action, :ref, :target_ref, :params])
      |> Map.put(:result, result)

    %{state | executed_steps: [executed_step | state.executed_steps]}
  end

  defp execution_summary(dry_run, state) do
    %{
      template: dry_run.template,
      step_count: dry_run.step_count,
      executed_steps: Enum.reverse(state.executed_steps),
      refs: state.refs
    }
  end

  defp resolve_cwd(nil, _workspace_root), do: {:ok, nil}
  defp resolve_cwd("", _workspace_root), do: {:ok, nil}
  defp resolve_cwd(path, nil) when is_binary(path), do: {:ok, path}

  defp resolve_cwd(path, workspace_root) when is_binary(path) and is_binary(workspace_root) do
    DevIDE.Files.PathSafety.resolve(workspace_root, path)
  end

  defp compact_opts(opts) do
    opts
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp ok(value), do: {:ok, value}
end
