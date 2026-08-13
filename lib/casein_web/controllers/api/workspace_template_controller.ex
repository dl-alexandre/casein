defmodule CaseinWeb.API.WorkspaceTemplateController do
  @moduledoc """
  Tmux session-template endpoints for a workspace: list, export (preview),
  save, apply (with dry-run/reconcile modes), update, duplicate, delete.

  Split out of `WorkspaceController` — same URLs
  (`/api/workspaces/:id/templates*`), same payload shapes. Mutations emit
  `tmux.template_*` audit events.
  """

  use CaseinWeb, :controller

  import CaseinWeb.API.WorkspaceAPI

  alias Casein.Audit
  alias Casein.Export
  alias Casein.Terminals
  alias Casein.Terminals.LayoutOps

  # Root every action in a fresh correlation context so the tmux.template_* audit
  # events these mutations emit are traced (Casein.Signals.EntryContext is the
  # LiveView analog; MCP tool calls get the same in each *_mcp.ex call_tool/3).
  def action(conn, _opts) do
    Casein.Signals.Context.with_new(fn ->
      apply(__MODULE__, action_name(conn), [conn, conn.params])
    end)
  end

  def templates(conn, %{"id" => id}) do
    case Export.status(id) do
      {:ok, _status} ->
        tag_filter = template_tag_filter(conn)

        built_in =
          if tag_filter == [],
            do: Enum.map(Terminals.session_templates(), &built_in_template_payload/1),
            else: []

        saved =
          Terminals.list_saved_templates(id, tags: tag_filter)
          |> Enum.map(&saved_template_list_payload/1)

        json(conn, built_in ++ saved)

      :error ->
        not_found(conn)
    end
  end

  def export_template(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, snapshot} <- snapshot_layout(conn, id, session, false) do
      json(conn, %{
        workspace_id: id,
        session: session,
        template: snapshot.template,
        yaml: snapshot.yaml
      })
    else
      :error -> not_found(conn)
      {:error, :empty_topology} -> rejected(conn, :unprocessable_entity, "empty_topology")
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def save_template(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, snapshot} <- snapshot_layout(conn, id, session, not dry_run?(conn)) do
      save_template_response(conn, id, session, snapshot)
    else
      :error ->
        not_found(conn)

      {:error, :empty_topology} ->
        rejected(conn, :unprocessable_entity, "empty_topology")

      {:error, %Ecto.Changeset{} = changeset} ->
        rejected(conn, :unprocessable_entity, changeset_error(changeset))

      {:error, reason} ->
        rejected(conn, :unprocessable_entity, reason)
    end
  end

  # One snapshot path shared with the `terminal_layout_snapshot` MCP tool.
  defp snapshot_layout(conn, workspace_id, session, save?) do
    LayoutOps.snapshot(workspace_id, session,
      workspace_root: workspace_root_for_export(workspace_id),
      name: param(conn, "name"),
      description: param(conn, "description"),
      tags: Map.get(conn.params, "tags"),
      save: save?
    )
  end

  def apply_template(conn, %{"id" => id, "template_id" => template_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      apply_template_mutation(conn, id, session, template_id)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def update_template(conn, %{"id" => id, "template_id" => template_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, saved} <- Terminals.get_saved_template(id, template_id),
         {:ok, updated} <-
           Terminals.update_saved_template(id, template_id, template_update_attrs(conn),
             dry_run: dry_run?(conn)
           ) do
      changes = template_update_changes(saved, updated)

      unless dry_run?(conn) do
        emit_tmux_template_updated_audit(id, updated, changes)
      end

      json(conn, template_update_payload(conn, id, updated, changes))
    else
      :error -> not_found(conn)
      {:error, :not_found} -> rejected(conn, :not_found, "template_not_found")
      {:error, :name_required} -> rejected(conn, :unprocessable_entity, "name_required")
      {:error, :name_taken} -> rejected(conn, :conflict, "name_taken")
      {:error, :invalid_tags} -> rejected(conn, :unprocessable_entity, "invalid_tags")
    end
  end

  def duplicate_template(conn, %{"id" => id, "template_id" => template_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, duplicated} <-
           Terminals.duplicate_saved_template(id, template_id, template_duplicate_attrs(conn),
             dry_run: dry_run?(conn)
           ) do
      unless dry_run?(conn) do
        emit_tmux_template_duplicated_audit(id, template_id, duplicated)
      end

      json(conn, template_duplicate_payload(conn, id, template_id, duplicated))
    else
      :error -> not_found(conn)
      {:error, :not_found} -> rejected(conn, :not_found, "template_not_found")
      {:error, :name_required} -> rejected(conn, :unprocessable_entity, "name_required")
      {:error, :name_taken} -> rejected(conn, :conflict, "name_taken")
      {:error, :invalid_tags} -> rejected(conn, :unprocessable_entity, "invalid_tags")
    end
  end

  def delete_template(conn, %{"id" => id, "template_id" => template_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, saved} <- Terminals.get_saved_template(id, template_id),
         :ok <- Terminals.delete_saved_template(id, template_id) do
      emit_tmux_template_deleted_audit(id, saved)

      json(conn, %{
        action: "template_deleted",
        workspace_id: id,
        template_id: template_id
      })
    else
      :error -> not_found(conn)
      {:error, :not_found} -> rejected(conn, :not_found, "template_not_found")
    end
  end

  # ---------------------------------------------------------------------------
  # Apply pipeline (dry-run / reconcile / execute)

  defp apply_template_mutation(conn, workspace_id, session, template_id) do
    cond do
      dry_run?(conn) and reconcile?(conn) ->
        case dry_run_template_diff(workspace_id, session, template_id) do
          {:ok, plan} ->
            json(conn, %{
              action: "template_applied",
              dry_run: true,
              reconcile: true,
              result: plan.result,
              diff: plan.diff,
              topology: plan.topology
            })

          {:error, :template_not_found} ->
            rejected(conn, :not_found, "template_not_found")

          {:error, reason} ->
            rejected(conn, :unprocessable_entity, reason)
        end

      reconcile?(conn) ->
        with {:ok, result} <- execute_template_reconcile(workspace_id, session, template_id) do
          json(
            conn,
            template_reconcile_mutation_payload(result)
          )
        else
          {:error, :template_not_found} ->
            rejected(conn, :not_found, "template_not_found")

          {:error, {reason, change, partial}} ->
            template_step_error(conn, reason, change, partial)

          {:error, reason} ->
            rejected(conn, :unprocessable_entity, reason)
        end

      dry_run?(conn) ->
        case dry_run_template(workspace_id, template_id) do
          {:ok, result} ->
            json(conn, %{
              action: "template_applied",
              dry_run: true,
              result: result,
              topology: topology_payload(workspace_id, session)
            })

          {:error, :template_not_found} ->
            rejected(conn, :not_found, "template_not_found")

          {:error, reason} ->
            rejected(conn, :unprocessable_entity, reason)
        end

      true ->
        with {:ok, root} <- workspace_root(workspace_id),
             {:ok, result} <-
               execute_template(workspace_id, session, template_id, root) do
          json(conn, template_mutation_payload(workspace_id, session, template_id, result))
        else
          {:error, :template_not_found} ->
            rejected(conn, :not_found, "template_not_found")

          {:error, {reason, step, partial}} ->
            template_step_error(conn, reason, step, partial)

          {:error, reason} ->
            rejected(conn, :unprocessable_entity, reason)
        end
    end
  end

  # Both reconcile paths run through Casein.Terminals.LayoutOps on the
  # `:operator` lane — the same context the `terminal_layout_apply` MCP tool
  # calls on its stricter `:agent` lane, so the two surfaces cannot drift.
  defp dry_run_template_diff(workspace_id, session, template_id) do
    LayoutOps.plan(workspace_id, session, template_id,
      workspace_root: workspace_root_for_export(workspace_id)
    )
  end

  defp execute_template_reconcile(workspace_id, session, template_id) do
    # Reconcilability is judged before the workspace root so a built-in id still
    # reports unsupported_reconcile in a workspace with no host path.
    with :ok <- LayoutOps.reconcilable(template_id),
         {:ok, root} <- workspace_root(workspace_id) do
      LayoutOps.apply_plan(workspace_id, session, template_id,
        tmux: tmux_adapter(),
        workspace_root: root
      )
    end
  end

  defp dry_run_template(workspace_id, template_id) do
    case Terminals.dry_run_session_template(template_id) do
      {:ok, result} ->
        {:ok, result}

      {:error, :template_not_found} ->
        Terminals.dry_run_saved_template(workspace_id, template_id)

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_template(workspace_id, session, template_id, root) do
    opts = [tmux: tmux_adapter(), workspace_root: root]

    case Terminals.execute_session_template(session, template_id, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, :template_not_found} ->
        Terminals.execute_saved_template(workspace_id, session, template_id, opts)

      {:error, _reason} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Payloads

  defp template_mutation_payload(workspace_id, session, template_id, result) do
    topology = refreshed_topology_payload(workspace_id, session)
    LayoutOps.audit_applied(workspace_id, session, template_id, result, topology)

    %{
      action: "template_applied",
      dry_run: false,
      result: result,
      topology: topology
    }
  end

  # Topology refresh and the tmux.template_applied audit both happen inside
  # LayoutOps.apply_plan/4, so every surface that applies a layout emits the
  # same event with the same post-mutation topology.
  defp template_reconcile_mutation_payload(result) do
    %{
      action: "template_applied",
      dry_run: false,
      reconcile: true,
      result: result.execution,
      diff: result.diff,
      summary: result.summary,
      topology: result.topology
    }
  end

  defp save_template_response(conn, workspace_id, session, snapshot) do
    if dry_run?(conn) do
      json(conn, %{
        action: "template_exported",
        dry_run: true,
        workspace_id: workspace_id,
        session: session,
        template: snapshot.template,
        yaml: snapshot.yaml,
        topology: snapshot.topology
      })
    else
      saved_payload = saved_template_detail_payload(snapshot.saved)

      conn
      |> put_status(:created)
      |> json(%{
        action: "template_exported",
        dry_run: false,
        workspace_id: workspace_id,
        session: session,
        result: saved_payload,
        saved_template: saved_payload,
        template: snapshot.template,
        yaml: snapshot.yaml,
        topology: snapshot.topology
      })
    end
  end

  defp template_update_attrs(conn) do
    %{}
    |> maybe_put_update_attr("name", Map.get(conn.params, "name"))
    |> maybe_put_update_attr("description", Map.get(conn.params, "description"))
    |> maybe_put_update_attr("tags", Map.get(conn.params, "tags"))
  end

  defp template_duplicate_attrs(conn), do: template_update_attrs(conn)

  defp maybe_put_update_attr(attrs, _key, nil), do: attrs
  defp maybe_put_update_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp template_update_changes(before, after_update) do
    [:name, :description, :tags]
    |> Enum.reduce(%{}, fn field, acc ->
      before_value = Map.get(before, field)
      after_value = Map.get(after_update, field)

      if before_value == after_value do
        acc
      else
        Map.put(acc, field, %{before: before_value, after: after_value})
      end
    end)
  end

  defp template_update_payload(conn, workspace_id, updated, changes) do
    payload = %{
      action: "template_updated",
      dry_run: dry_run?(conn),
      workspace_id: workspace_id,
      template_id: updated.id,
      changes: changes,
      template: saved_template_detail_payload(updated)
    }

    case optional_topology_payload(conn, workspace_id) do
      nil -> payload
      topology -> Map.put(payload, :topology, topology)
    end
  end

  defp template_duplicate_payload(conn, workspace_id, source_template_id, duplicated) do
    duplicated_payload = saved_template_detail_payload(duplicated)

    payload = %{
      action: "template_duplicated",
      dry_run: dry_run?(conn),
      workspace_id: workspace_id,
      source_template_id: source_template_id,
      template_id: duplicated.id,
      result: duplicated_payload,
      saved_template: duplicated_payload
    }

    case optional_topology_payload(conn, workspace_id) do
      nil -> payload
      topology -> Map.put(payload, :topology, topology)
    end
  end

  defp built_in_template_payload(%{
         id: id,
         name: name,
         description: description,
         windows: windows
       }) do
    %{
      id: id,
      name: name,
      description: description,
      source: "built_in",
      schema_version: 1,
      apply_supported: true,
      tags: [],
      windows: length(windows),
      panes:
        length(windows) +
          (windows
           |> Enum.map(&length(&1.panes))
           |> Enum.sum())
    }
  end

  defp saved_template_list_payload(saved) do
    body = saved.body || %{}
    windows = Map.get(body, "windows", [])

    %{
      id: saved.id,
      name: saved.name,
      description: saved.description,
      source: "exported",
      schema_version: saved.schema_version,
      apply_supported: Terminals.saved_template_apply_supported?(saved),
      source_session: saved.source_session,
      tags: saved.tags || [],
      windows: length(windows),
      panes: Enum.map(windows, &layout_pane_count(Map.get(&1, "layout", %{}))) |> Enum.sum(),
      inserted_at: saved.inserted_at,
      updated_at: saved.updated_at
    }
  end

  defp saved_template_detail_payload(saved) do
    saved
    |> saved_template_list_payload()
    |> Map.put(:workspace_id, saved.workspace_id)
  end

  defp layout_pane_count(%{"panes" => panes}) when is_list(panes) do
    case panes do
      [] -> 1
      _ -> Enum.map(panes, &layout_pane_count/1) |> Enum.sum()
    end
  end

  defp layout_pane_count(_layout), do: 1

  defp template_tag_filter(conn) do
    [
      Map.get(conn.params, "tag"),
      Map.get(conn.params, "tags"),
      get_in(conn.params, ["filter", "tag"]),
      get_in(conn.params, ["filter", "tags"])
    ]
    |> Enum.reject(&is_nil/1)
    |> List.flatten()
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ",", trim: true)
      value -> [value]
    end)
    |> Enum.map(
      &(to_string(&1)
        |> String.trim()
        |> String.downcase()
        |> String.replace(~r/\s+/, "-"))
    )
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp template_step_error(conn, reason, step, partial) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "template_step_failed",
      reason: inspect(reason),
      step: step,
      partial_result: partial
    })
  end

  # ---------------------------------------------------------------------------
  # Audit

  defp emit_tmux_template_deleted_audit(workspace_id, saved) do
    Audit.emit!(%{
      action: "tmux.template_deleted",
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_template",
      target_ref: saved.id,
      metadata: %{
        template_id: saved.id,
        template_name: saved.name,
        schema_version: saved.schema_version,
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_updated_audit(workspace_id, saved, changes) do
    Audit.emit!(%{
      action: "tmux.template_updated",
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_template",
      target_ref: saved.id,
      metadata: %{
        template_id: saved.id,
        template_name: saved.name,
        schema_version: saved.schema_version,
        changes: changes,
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_duplicated_audit(workspace_id, source_template_id, duplicated) do
    Audit.emit!(%{
      action: "tmux.template_duplicated",
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_template",
      target_ref: duplicated.id,
      metadata: %{
        source_template_id: source_template_id,
        template_id: duplicated.id,
        template_name: duplicated.name,
        schema_version: duplicated.schema_version,
        dry_run: false
      }
    })
  end
end
