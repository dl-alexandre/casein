defmodule Casein.Agents.TerminalTools.Impl.Layout do
  @moduledoc """
  Agent-lane glue for declarative session layout.

  Resolves the caller's workspace session the same way every other terminal
  tool does, then hands off to `Casein.Terminals.LayoutOps` on the `:agent`
  lane — the same context the HTTP template endpoints use on the `:operator`
  lane. Nothing tmux-shaped happens here.

  The agent lane is deliberately narrower than the operator's: it plans by
  default, executes only against a plan digest the caller has already seen,
  never moves focus, refuses a plan carrying a command the workspace's terminal
  command policy blocks, and always saves an undo snapshot first. Windows and
  panes can be added or filled, never closed.
  """

  alias Casein.Terminals.LayoutOps

  import Casein.Agents.TerminalTools.Impl.Shared

  @doc "Plan (default) or apply a saved layout template for the caller's session."
  @spec apply_layout(map()) :: {:ok, map()} | {:error, term()}
  def apply_layout(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params),
         {:ok, template_id} <- string_arg(params, "template_id") do
      opts = [
        lane: :agent,
        workspace_root: workspace_root(workspace_id),
        actor_id: actor_id(params),
        tmux: tmux()
      ]

      if dry_run?(params) do
        plan(workspace_id, session, template_id, opts)
      else
        apply_now(workspace_id, session, template_id, params, opts)
      end
    end
  end

  defp plan(workspace_id, session, template_id, opts) do
    with {:ok, plan} <- LayoutOps.plan(workspace_id, session, template_id, opts) do
      {:ok,
       %{
         ok: true,
         mode: "planned",
         applied?: false,
         session: session,
         template_id: template_id,
         plan_digest: plan.digest,
         change_count: length(plan.changes),
         changes: Enum.map(plan.changes, &compact_change/1),
         skipped: Enum.map(plan.skipped, &compact_change/1),
         summary: plan.diff.summary,
         estimated_disruption: plan.diff.estimated_disruption,
         additive_only?: true,
         focus_unchanged?: true
       }
       |> put_next("terminal_layout_apply", %{
         workspace_id: workspace_id,
         session: session,
         template_id: template_id,
         dry_run: false,
         plan_digest: plan.digest
       })}
    end
  end

  defp apply_now(workspace_id, session, template_id, params, opts) do
    opts = Keyword.put(opts, :expect_digest, string_param(params, "plan_digest"))

    with {:ok, result} <- LayoutOps.apply_plan(workspace_id, session, template_id, opts) do
      {:ok,
       %{
         ok: true,
         mode: "applied",
         applied?: true,
         session: session,
         template_id: template_id,
         plan_digest: result.digest,
         executed_count: length(result.execution.executed_changes),
         executed: Enum.map(result.execution.executed_changes, &compact_change/1),
         skipped: Enum.map(result.skipped, &compact_change/1),
         summary: result.summary,
         focus_unchanged?: true,
         undo: result.undo
       }
       |> put_undo_next(workspace_id, session, result.undo)}
    end
  end

  @doc "Export the caller's live session layout as a saved template."
  @spec snapshot_layout(map()) :: {:ok, map()} | {:error, term()}
  def snapshot_layout(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_or_default_arg(params) do
      # Snapshot saves unless asked not to — an unsaved undo point is no undo
      # point. (Apply is the opposite: it plans unless told to execute.)
      save? = not dry_run?(params, false)

      opts = [
        lane: :agent,
        workspace_root: workspace_root(workspace_id),
        actor_id: actor_id(params),
        name: string_param(params, "name"),
        description: string_param(params, "description"),
        tags: tags(params),
        save: save?
      ]

      with {:ok, snapshot} <- LayoutOps.snapshot(workspace_id, session, opts) do
        {:ok, snapshot_payload(workspace_id, session, snapshot, save?)}
      end
    end
  end

  defp snapshot_payload(workspace_id, session, snapshot, save?) do
    windows = Map.get(snapshot.template, "windows", [])

    payload = %{
      ok: true,
      saved?: save?,
      session: session,
      name: snapshot.template["name"],
      window_count: length(windows),
      schema_version: snapshot.template["version"] || 2
    }

    case snapshot.saved do
      nil ->
        Map.put(payload, :template_id, nil)

      saved ->
        payload
        |> Map.put(:template_id, saved.id)
        |> Map.put(:name, saved.name)
        |> put_next("terminal_layout_apply", %{
          workspace_id: workspace_id,
          session: session,
          template_id: saved.id,
          dry_run: true
        })
    end
  end

  # Applying the undo snapshot is itself an apply, so hand back the arguments
  # that plan it rather than describing the undo in prose.
  defp put_undo_next(payload, workspace_id, session, %{template_id: template_id}) do
    put_next(payload, "terminal_layout_apply", %{
      workspace_id: workspace_id,
      session: session,
      template_id: template_id,
      dry_run: true
    })
  end

  defp put_undo_next(payload, _workspace_id, _session, _undo), do: payload

  defp compact_change(change) when is_map(change) do
    %{
      index: Map.get(change, :index),
      action: Map.get(change, :action),
      target_id: Map.get(change, :target_id),
      ref: get_in(change, [:template_ref, :ref]),
      reason: Map.get(change, :reason) || Map.get(change, :skipped_reason),
      direction: Map.get(change, :direction),
      command: Map.get(change, :command)
    }
    |> compact()
  end

  # `||` is wrong for a boolean argument: an explicit `dry_run: false` is
  # falsy and would fall through to the default, i.e. silently refuse to
  # execute (or, on snapshot, silently refuse to save).
  defp dry_run?(params, default \\ true) do
    case Casein.PayloadAttrs.fetch(params, "dry_run") do
      {:ok, nil} -> default
      {:ok, value} -> truthy?(value)
      :error -> default
    end
  end

  defp tags(params) do
    case Map.get(params, "tags") || Map.get(params, :tags) do
      tags when is_list(tags) -> tags
      tag when is_binary(tag) and tag != "" -> [tag]
      _ -> nil
    end
  end

  defp actor_id(params), do: string_param(params, "actor_id") || "agent"

  defp workspace_root(workspace_id) do
    case LayoutOps.workspace_root(workspace_id) do
      {:ok, root} -> root
      {:error, _reason} -> nil
    end
  end
end
