defmodule Casein.Terminals.Templates.ReconcileExecutor do
  @moduledoc """
  Executes saved-template reconciliation diffs.

  This consumes the read-only plan produced by `Templates.Reconciler` and only
  performs additive/selective actions: reuse existing windows/panes, create
  missing windows, split missing panes, send commands, and restore focus.
  """

  alias Casein.Panes.Pane, as: PaneBehaviour
  alias Casein.Terminals.SessionTemplate.Pane
  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxTopology

  @spec execute(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(session, diff, opts \\ []) when is_binary(session) and is_map(diff) do
    state = %{
      session: session,
      tmux: Keyword.get(opts, :tmux, Tmux),
      workspace_root: Keyword.get(opts, :workspace_root),
      workspace_id: Keyword.get(opts, :workspace_id),
      refs: %{},
      executed_changes: []
    }

    diff.changes
    |> Enum.reduce_while({:ok, state}, fn change, {:ok, state} ->
      case execute_change(change, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, {reason, change, execution_summary(diff, state)}}}
      end
    end)
    |> case do
      {:ok, state} ->
        {:ok,
         %{
           template: diff.template,
           strategy: "reconcile",
           step_count: length(diff.changes),
           executed_changes: Enum.reverse(state.executed_changes),
           refs: state.refs,
           reconciliation: diff.summary,
           estimated_disruption: diff.estimated_disruption
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_change(%{action: "reuse_window"} = change, state) do
    with {:ok, ref} <- template_ref(change),
         {:ok, target_id} <- target_id(change) do
      state
      |> put_ref(ref, target_id)
      |> record_change(change, %{window_id: target_id, reused: true})
      |> ok()
    end
  end

  defp execute_change(%{action: "create_window"} = change, state) do
    with {:ok, ref} <- template_ref(change),
         {:ok, cwd} <- resolve_cwd(get_in(change, [:template_ref, :cwd]), state.workspace_root),
         opts <- compact_opts(name: get_in(change, [:template_ref, :name]), cwd: cwd),
         {:ok, window_id} <- state.tmux.new_window(state.session, opts),
         {:ok, root_pane_id} <- active_pane_for_window(state, window_id) do
      state
      |> put_ref(ref, window_id)
      |> put_ref(root_ref(ref), root_pane_id)
      |> record_change(change, %{window_id: window_id, root_pane_id: root_pane_id})
      |> ok()
    end
  end

  defp execute_change(%{action: "reuse_pane"} = change, state) do
    with {:ok, ref} <- template_ref(change),
         {:ok, target_id} <- target_id(change) do
      state
      |> put_ref(ref, target_id)
      |> record_change(change, %{pane_id: target_id, reused: true})
      |> ok()
    end
  end

  defp execute_change(%{action: "split_pane"} = change, state) do
    with {:ok, ref} <- template_ref(change),
         {:ok, target_pane_id} <- target_pane_id(change, state),
         {:ok, cwd} <- resolve_cwd(get_in(change, [:template_ref, :cwd]), state.workspace_root),
         opts <- compact_opts(cwd: cwd),
         {:ok, pane_id} <-
           state.tmux.split_pane(
             state.session,
             target_pane_id,
             change.direction,
             opts
           ) do
      state
      |> put_ref(ref, pane_id)
      |> record_change(change, %{pane_id: pane_id, target_pane_id: target_pane_id})
      |> ok()
    end
  end

  defp execute_change(%{action: "send_command"} = change, state) do
    with {:ok, pane_id} <- pane_id(change, state),
         :ok <- state.tmux.send_command(state.session, change.command, target: pane_id) do
      state
      |> record_change(change, %{target_pane_id: pane_id})
      |> ok()
    end
  end

  defp execute_change(%{action: "select_pane"} = change, state) do
    with {:ok, pane_id} <- pane_id(change, state),
         :ok <- state.tmux.select_pane(state.session, pane_id) do
      state
      |> record_change(change, %{pane_id: pane_id})
      |> ok()
    end
  end

  defp execute_change(%{action: "attach_pane"} = change, state) do
    with {:ok, pane_id} <- pane_id(change, state) do
      state
      |> record_change(change, attach_pane(change, pane_id, state))
      |> ok()
    end
  end

  defp execute_change(change, _state), do: {:error, {:unsupported_change, change.action}}

  # Bring a non-terminal pane to life via the Pane behaviour after its tmux slot
  # exists (split_pane/reuse_pane allocated the geometry). Attach failure degrades to
  # a recorded error rather than failing the reconcile.
  defp attach_pane(change, pane_id, state) do
    type = Pane.cast_type(Map.get(change, :type))
    node = %{command: Map.get(change, :command), cwd: Map.get(change, :cwd)}

    ctx = %{
      pane_id: pane_id,
      workspace_id: state.workspace_id,
      tmux_session: state.session
    }

    case PaneBehaviour.impl(type).attach(node, ctx) do
      {:ok, ref} -> %{target_pane_id: pane_id, attached: ref}
      {:error, reason} -> %{target_pane_id: pane_id, attach_error: inspect(reason)}
    end
  end

  defp active_pane_for_window(state, window_id) do
    topology = TmuxTopology.snapshot(state.session, tmux: state.tmux)

    topology.windows
    |> Enum.find(&(&1.id == window_id))
    |> case do
      %{pane_list: [%{id: pane_id} | _]} -> {:ok, pane_id}
      _ -> {:error, :root_pane_not_found}
    end
  end

  defp target_pane_id(change, state) do
    case target_id(change) do
      {:ok, pane_id} ->
        {:ok, pane_id}

      {:error, :missing_target_id} ->
        change
        |> get_in([:template_ref, :target_ref])
        |> resolve_ref(state)
    end
  end

  defp pane_id(change, state) do
    case target_id(change) do
      {:ok, pane_id} ->
        {:ok, pane_id}

      {:error, :missing_target_id} ->
        with {:ok, ref} <- template_ref(change) do
          resolve_ref(ref, state)
        end
    end
  end

  defp target_id(%{target_id: target_id}) when is_binary(target_id) and target_id != "",
    do: {:ok, target_id}

  defp target_id(_change), do: {:error, :missing_target_id}

  defp template_ref(%{template_ref: %{ref: ref}}) when is_binary(ref) and ref != "",
    do: {:ok, ref}

  defp template_ref(_change), do: {:error, :missing_template_ref}

  defp root_ref("window:" <> window_id), do: "pane:" <> window_id <> ":root"
  defp root_ref(ref), do: ref <> ":root"

  defp put_ref(state, ref, value), do: %{state | refs: Map.put(state.refs, ref, value)}

  defp resolve_ref(nil, _state), do: {:error, :missing_ref}

  defp resolve_ref(ref, %{refs: refs}) when is_binary(ref) do
    case Map.fetch(refs, ref) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unresolved_ref, ref}}
    end
  end

  defp record_change(state, change, result) do
    executed_change =
      change
      |> Map.take([:index, :action, :target_id, :template_ref, :current_ref, :reason])
      |> Map.put(:result, result)

    %{state | executed_changes: [executed_change | state.executed_changes]}
  end

  defp execution_summary(diff, state) do
    %{
      template: diff.template,
      strategy: "reconcile",
      step_count: length(diff.changes),
      executed_changes: Enum.reverse(state.executed_changes),
      refs: state.refs,
      reconciliation: diff.summary,
      estimated_disruption: diff.estimated_disruption
    }
  end

  defp resolve_cwd(nil, _workspace_root), do: {:ok, nil}
  defp resolve_cwd("", _workspace_root), do: {:ok, nil}
  defp resolve_cwd(path, nil) when is_binary(path), do: {:ok, path}

  defp resolve_cwd("${workspace_root}", workspace_root) when is_binary(workspace_root),
    do: {:ok, workspace_root}

  defp resolve_cwd("${workspace_root}/" <> relative, workspace_root)
       when is_binary(workspace_root) do
    Casein.Files.PathSafety.resolve(workspace_root, relative)
  end

  defp resolve_cwd(path, workspace_root) when is_binary(path) and is_binary(workspace_root) do
    Casein.Files.PathSafety.resolve(workspace_root, path)
  end

  defp compact_opts(opts) do
    opts
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp ok(value), do: {:ok, value}
end
