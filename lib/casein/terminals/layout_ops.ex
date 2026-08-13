defmodule Casein.Terminals.LayoutOps do
  @moduledoc """
  One mutate path for declarative session layout: snapshot (export) and
  reconcile-apply.

  `CaseinWeb.API.WorkspaceTemplateController` (HTTP) and the
  `terminal_layout_*` MCP tools both go through here, so the two surfaces
  cannot drift on what a reconcile plan is, which topology it is planned
  against, or which audit event a mutation emits.

  ## Two lanes, one execution path

    * `:operator` — the viewer/API lane. Executes the reconciler's plan as
      written, focus restore included. This is the pre-existing behaviour and
      is unchanged.
    * `:agent` — the MCP lane. Strictly narrower (see `plan/4`): focus changes
      are stripped, every `send_command` in the plan must pass
      `Casein.Agents.TerminalCommandPolicy`, an undo snapshot must exist before
      execution, and the caller must present the digest of a plan it has
      already seen — dry run first, then apply.

  ## What no lane can do

  Neither lane can close a window or a pane. The reconciler is additive by
  construction (`reuse_*`, `create_window`, `split_pane`, `send_command`,
  `attach_pane`, plus `select_pane` for focus), and `validate_plan/2` refuses
  any change action outside that allowlist rather than executing it. That is
  what keeps the promise structurally rather than by inspection: there is no
  code path here that can close the caller's pane, the last pane in a session,
  an operator pane, or a `Casein.FilePanes` / preview pane behind its owner's
  back — because there is no close at all. A future reconciler that learns to
  emit `kill_pane` fails the guard instead of inheriting permission.

  Geometry and focus stay with the operator: agents declare which layout they
  want, never where it goes.
  """

  alias Casein.Agents.TerminalCommandPolicy
  alias Casein.Audit
  alias Casein.Terminals
  alias Casein.Terminals.Templates.ReconcileExecutor
  alias Casein.Terminals.WindowTrash

  @typedoc "Execution lane; `:agent` is the strict MCP lane."
  @type lane :: :operator | :agent

  # Every change action the reconciler can emit that adds or fills something.
  @additive_actions ~w(reuse_window create_window reuse_pane split_pane send_command attach_pane)

  # Focus. Executed for the operator (restoring startup focus is what they
  # asked for by clicking Apply), always stripped for an agent.
  @focus_actions ~w(select_pane)

  @digest_bytes 16

  # ---------------------------------------------------------------------------
  # Topology

  @doc """
  Trash-filtered topology payload for a workspace session.

  Windows closed through the undoable path are still alive in tmux during their
  grace period but are gone as far as callers are concerned, so they are
  filtered here — a reconcile plan must never reuse a window the operator has
  been told is closed.
  """
  @spec topology(String.t(), String.t()) :: map()
  def topology(workspace_id, session) when is_binary(session) do
    topology = Terminals.tmux_topology_snapshot(session)
    windows = WindowTrash.reject_pending(session, topology.windows)
    visible_ids = MapSet.new(windows, & &1.id)

    %{
      workspace_id: workspace_id,
      session: topology.session,
      active_window_id: topology.active_window_id,
      active_pane_id: topology.active_pane_id,
      version: topology.version,
      windows: windows,
      panes: Enum.filter(topology.panes || [], &MapSet.member?(visible_ids, &1.window_id))
    }
  end

  @doc "Refresh tmux topology state, then read it back."
  @spec refreshed_topology(String.t(), String.t()) :: map()
  def refreshed_topology(workspace_id, session) do
    _ = Terminals.configure_tmux_topology(session, workspace_id: workspace_id)
    _ = Terminals.refresh_tmux_topology(session)
    topology(workspace_id, session)
  end

  # ---------------------------------------------------------------------------
  # Plan

  @doc """
  Build a reconcile plan for `template_id` against the session's live topology.

  Returns `{:ok, plan}` where plan carries the raw `:diff` (unchanged wire
  shape for existing HTTP consumers), the lane-filtered `:changes` that would
  actually execute, the `:skipped` changes and why, and a `:digest` over the
  executable changes.

  The digest is what makes "dry run first" enforceable rather than advisory:
  `apply/4` in the `:agent` lane requires the caller to hand back a digest that
  still matches the plan computed from the topology as it is *now*. A layout
  that moved under the agent between planning and applying fails closed with
  `:plan_stale` instead of executing against a session it no longer describes.

  Options:

    * `:lane` — `:operator` (default) or `:agent`
    * `:workspace_root` — root for `${workspace_root}` expansion
    * `:topology` — pre-read topology (defaults to `topology/2`)
  """
  @spec plan(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(workspace_id, session, template_id, opts \\ []) do
    lane = lane(opts)
    topology = Keyword.get_lazy(opts, :topology, fn -> topology(workspace_id, session) end)

    with :ok <- reconcilable(template_id),
         {:ok, diff} <-
           Terminals.diff_saved_template(workspace_id, template_id, topology,
             workspace_root: Keyword.get(opts, :workspace_root)
           ),
         {:ok, changes, skipped} <- validate_plan(diff.changes, lane) do
      {:ok,
       %{
         diff: diff,
         topology: topology,
         lane: lane,
         changes: changes,
         skipped: skipped,
         digest: digest(changes),
         result: plan_result(diff)
       }}
    end
  end

  @doc """
  Split a reconciler plan into what this lane may execute and what it refuses.

  Anything outside the additive allowlist is a hard refusal for both lanes —
  that is the no-close guarantee. Focus changes are executable for an operator
  and stripped (not refused) for an agent, so an agent applying a layout never
  yanks the operator's cursor into a different pane.
  """
  @spec validate_plan([map()], lane()) :: {:ok, [map()], [map()]} | {:error, map()}
  def validate_plan(changes, lane) when is_list(changes) do
    allowed = @additive_actions ++ @focus_actions

    case Enum.filter(changes, &(&1.action not in allowed)) do
      [] ->
        {executable, skipped} = partition_focus(changes, lane)
        {:ok, executable, skipped}

      refused ->
        {:error, destructive_error(refused)}
    end
  end

  defp partition_focus(changes, :operator), do: {changes, []}

  defp partition_focus(changes, :agent) do
    {focus, executable} = Enum.split_with(changes, &(&1.action in @focus_actions))

    {executable,
     Enum.map(focus, fn change ->
       change
       |> Map.take([:index, :action, :target_id, :template_ref])
       |> Map.put(:skipped_reason, "focus_belongs_to_operator")
     end)}
  end

  defp destructive_error(refused) do
    %{
      error: :destructive_change_refused,
      message:
        "A reconcile plan may only add: #{Enum.join(@additive_actions, ", ")}. " <>
          "Refused #{length(refused)} change(s) that would do something else. " <>
          "Closing a window or pane is not available on this path at all.",
      refused: Enum.map(refused, &Map.take(&1, [:index, :action, :target_id]))
    }
  end

  # ---------------------------------------------------------------------------
  # Apply

  @doc """
  Execute a reconcile plan.

  Operator lane: plans and executes, preserving the previous behaviour exactly.

  Agent lane, all of which must hold or nothing runs:

    * the plan must be additive (`validate_plan/2`)
    * every `send_command` must pass `Casein.Agents.TerminalCommandPolicy` —
      without this a saved template is an arbitrary-shell-execution bypass
      around the policy that guards `terminal_send_command`
    * `:expect_digest` must match the current plan (`:plan_stale` otherwise)
    * an undo snapshot must be saved first, or the apply is refused with
      `:snapshot_failed` — an apply with no way back is not offered

  Options: `:lane`, `:workspace_root`, `:actor_id`, `:expect_digest`, `:tmux`.
  """
  @spec apply_plan(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_plan(workspace_id, session, template_id, opts \\ []) do
    lane = lane(opts)

    with {:ok, plan} <- plan(workspace_id, session, template_id, opts),
         :ok <- check_digest(plan, lane, Keyword.get(opts, :expect_digest)),
         :ok <- authorize_commands(plan.changes, lane),
         {:ok, undo} <- undo_snapshot(workspace_id, session, lane, template_id, opts),
         {:ok, execution} <- execute(session, plan, opts) do
      topology = refreshed_topology(workspace_id, session)
      execution = Map.put(execution, :plan_executed, true)

      audit_applied(workspace_id, session, template_id, execution, topology, opts)

      {:ok,
       %{
         diff: plan.diff,
         execution: execution,
         summary: plan.diff.summary,
         skipped: plan.skipped,
         digest: plan.digest,
         undo: undo,
         topology: topology
       }}
    end
  end

  defp execute(session, plan, opts) do
    executable = %{plan.diff | changes: plan.changes}

    ReconcileExecutor.execute(
      session,
      executable,
      Keyword.take(opts, [:tmux, :workspace_root, :workspace_id])
    )
  end

  defp check_digest(_plan, :operator, _expected), do: :ok
  defp check_digest(%{digest: digest}, :agent, digest), do: :ok

  defp check_digest(plan, :agent, expected) do
    {:error,
     %{
       error: :plan_stale,
       message:
         if(is_nil(expected),
           do:
             "Apply requires the digest of a plan you have already seen. " <>
               "Call again with dry_run true, read plan_digest, then pass it back.",
           else:
             "The layout changed since that plan was made. Re-run with dry_run true " <>
               "and apply the new plan_digest."
         ),
       expected_digest: expected,
       plan_digest: plan.digest,
       change_count: length(plan.changes)
     }}
  end

  # A saved template's send_command steps are shell commands. Applying a
  # template must therefore obey the same allow/denylist as calling
  # terminal_send_command directly, or the template becomes the way around it.
  defp authorize_commands(_changes, :operator), do: :ok

  defp authorize_commands(changes, :agent) do
    changes
    |> Enum.filter(&(&1.action == "send_command"))
    |> Enum.reduce_while(:ok, fn change, :ok ->
      case TerminalCommandPolicy.authorize("terminal_send_command", %{
             "command" => Map.get(change, :command)
           }) do
        :ok -> {:cont, :ok}
        {:error, blocked} -> {:halt, {:error, command_blocked_error(change, blocked)}}
      end
    end)
  end

  defp command_blocked_error(change, blocked) do
    %{
      error: :command_blocked,
      message:
        "This template runs a command the workspace's terminal command policy blocks. " <>
          "Nothing was applied.",
      command: Map.get(change, :command),
      change_index: Map.get(change, :index),
      policy: blocked
    }
  end

  defp undo_snapshot(_workspace_id, _session, :operator, _template_id, _opts), do: {:ok, nil}

  defp undo_snapshot(workspace_id, session, :agent, template_id, opts) do
    name = undo_name(template_id)

    case snapshot(workspace_id, session,
           name: name,
           description: "Automatic undo point captured before applying #{template_id}.",
           tags: ["undo"],
           save: true,
           actor_id: Keyword.get(opts, :actor_id),
           workspace_root: Keyword.get(opts, :workspace_root)
         ) do
      {:ok, %{saved: %{} = saved}} ->
        {:ok, %{template_id: saved.id, name: saved.name}}

      {:error, reason} ->
        {:error,
         %{
           error: :snapshot_failed,
           message:
             "Refusing to apply without an undo point. Could not snapshot the current " <>
               "layout first.",
           reason: inspect(reason)
         }}
    end
  end

  defp undo_name(template_id) do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    "undo before #{template_id} · #{stamp}"
  end

  # ---------------------------------------------------------------------------
  # Snapshot

  @doc """
  Export the session's live layout as a template, optionally saving it.

  This is the undo half of the pair: a saved snapshot is a template, so taking
  one back is just applying it. Saving is the default because that is the point;
  pass `save: false` for a preview.

  Options: `:name`, `:description`, `:tags`, `:save`, `:actor_id`,
  `:workspace_root`, `:inspectors`.
  """
  @spec snapshot(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(workspace_id, session, opts \\ []) do
    topology = topology(workspace_id, session)

    export_opts =
      [workspace_root: Keyword.get(opts, :workspace_root), name: Keyword.get(opts, :name)]
      |> maybe_put(:inspectors, Keyword.get(opts, :inspectors))

    with {:ok, template} <- Terminals.export_session_template(topology, export_opts) do
      base = %{
        workspace_id: workspace_id,
        session: session,
        template: template,
        yaml: Terminals.session_template_to_yaml(template),
        topology: topology
      }

      if Keyword.get(opts, :save, true) do
        save_snapshot(base, workspace_id, session, template, opts)
      else
        {:ok, Map.put(base, :saved, nil)}
      end
    end
  end

  defp save_snapshot(base, workspace_id, session, template, opts) do
    attrs = %{
      workspace_id: workspace_id,
      name: template["name"],
      description: Keyword.get(opts, :description),
      body: template,
      source_session: session,
      schema_version: template["version"] || 2,
      tags: Keyword.get(opts, :tags)
    }

    case Terminals.save_template(attrs) do
      {:ok, saved} ->
        emit_exported_audit(workspace_id, session, saved, base.topology, opts)
        {:ok, Map.put(base, :saved, saved)}

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ---------------------------------------------------------------------------
  # Shared helpers

  @doc "Workspace host path, used to expand `${workspace_root}` in a template."
  @spec workspace_root(String.t()) :: {:ok, String.t()} | {:error, :workspace_root_unavailable}
  def workspace_root(workspace_id) do
    case Casein.Workspaces.get_record(workspace_id) do
      {:ok, %{host_path: root}} when is_binary(root) -> {:ok, root}
      {:ok, _record} -> {:error, :workspace_root_unavailable}
      :error -> {:error, :workspace_root_unavailable}
    end
  end

  @doc "Reconcile applies to saved exports only; built-ins have no diff to take."
  @spec reconcilable(String.t()) :: :ok | {:error, :unsupported_reconcile}
  def reconcilable(template_id) do
    case Terminals.get_session_template(template_id) do
      {:ok, _built_in} -> {:error, :unsupported_reconcile}
      {:error, :template_not_found} -> :ok
    end
  end

  @doc "HTTP-shaped result summary for a reconcile diff."
  @spec plan_result(map()) :: map()
  def plan_result(diff) do
    %{
      template: diff.template,
      strategy: diff.strategy,
      step_count: length(diff.changes),
      summary: diff.summary,
      estimated_disruption: diff.estimated_disruption,
      changes: diff.changes
    }
  end

  @doc "Stable digest over the executable changes of a plan."
  @spec digest([map()]) :: String.t()
  def digest(changes) when is_list(changes) do
    changes
    |> Enum.map_join("\n", fn change ->
      [
        Map.get(change, :action),
        get_in(change, [:template_ref, :ref]),
        Map.get(change, :target_id),
        Map.get(change, :direction),
        Map.get(change, :command)
      ]
      |> Enum.map_join("|", &to_string(&1 || ""))
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @digest_bytes)
  end

  defp lane(opts) do
    case Keyword.get(opts, :lane, :operator) do
      :agent -> :agent
      _ -> :operator
    end
  end

  # ---------------------------------------------------------------------------
  # Audit

  @doc """
  Emit `tmux.template_applied`.

  Public so the exact-replay apply path (built-in templates, HTTP only) emits
  the identical event shape as the reconcile path rather than keeping a second
  copy of it in the controller.
  """
  @spec audit_applied(String.t(), String.t(), String.t(), map(), map(), keyword()) :: term()
  def audit_applied(workspace_id, session, template_id, result, topology, opts \\ []) do
    template = Map.get(result, :template, %{})

    Audit.emit!(%{
      action: "tmux.template_applied",
      workspace_id: workspace_id,
      actor_id: actor_id(opts),
      target_type: "tmux_template",
      target_ref: template_id,
      metadata: %{
        session: session,
        template_id: template_id,
        template_source: template_source(template),
        schema_version: template_schema_version(template),
        step_count: result.step_count,
        refs: result.refs,
        reconciliation: Map.get(result, :reconciliation),
        estimated_disruption: Map.get(result, :estimated_disruption),
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        lane: Atom.to_string(lane(opts)),
        dry_run: false
      }
    })
  end

  defp emit_exported_audit(workspace_id, session, saved, topology, opts) do
    Audit.emit!(%{
      action: "tmux.template_exported",
      workspace_id: workspace_id,
      actor_id: actor_id(opts),
      target_type: "tmux_template",
      target_ref: saved.id,
      metadata: %{
        session: session,
        template_id: saved.id,
        template_name: saved.name,
        schema_version: saved.schema_version,
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        lane: Atom.to_string(lane(opts)),
        dry_run: false
      }
    })
  end

  defp actor_id(opts) do
    case Keyword.get(opts, :actor_id) do
      actor when is_binary(actor) and actor != "" -> actor
      _ -> "api"
    end
  end

  defp template_source(%{source: source}) when is_binary(source), do: source
  defp template_source(%{"source" => source}) when is_binary(source), do: source
  defp template_source(_template), do: "built_in"

  defp template_schema_version(%{schema_version: version}) when is_integer(version), do: version

  defp template_schema_version(%{"schema_version" => version}) when is_integer(version),
    do: version

  defp template_schema_version(_template), do: 1
end
