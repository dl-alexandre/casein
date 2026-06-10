defmodule DevIdeWeb.API.WorkspaceTemplateController do
  @moduledoc """
  Tmux session-template endpoints for a workspace: list, export (preview),
  save, apply (with dry-run/reconcile modes), update, duplicate, delete.

  Split out of `WorkspaceController` — same URLs
  (`/api/workspaces/:id/templates*`), same payload shapes. Mutations emit
  `tmux.template_*` audit events.
  """

  use DevIdeWeb, :controller

  import DevIdeWeb.API.WorkspaceAPI

  alias DevIDE.Audit
  alias DevIDE.Export
  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.Templates
  alias DevIDE.Terminals.TmuxTopology

  def templates(conn, %{"id" => id}) do
    case Export.status(id) do
      {:ok, _status} ->
        tag_filter = template_tag_filter(conn)

        built_in =
          if tag_filter == [],
            do: Enum.map(SessionTemplate.list(), &built_in_template_payload/1),
            else: []

        saved =
          Templates.list_for_workspace(id, tags: tag_filter)
          |> Enum.map(&saved_template_list_payload/1)

        json(conn, built_in ++ saved)

      :error ->
        not_found(conn)
    end
  end

  def export_template(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         topology <- TmuxTopology.snapshot(session, tmux: tmux_adapter()),
         {:ok, template} <-
           SessionTemplate.export_topology(topology,
             workspace_root: workspace_root_for_export(id),
             name: param(conn, "name")
           ) do
      json(conn, %{
        workspace_id: id,
        session: session,
        template: template,
        yaml: DevIDE.Terminals.SessionTemplate.Export.to_yaml(template)
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
         topology <- TmuxTopology.snapshot(session, tmux: tmux_adapter()),
         {:ok, template} <-
           SessionTemplate.export_topology(topology,
             workspace_root: workspace_root_for_export(id),
             name: param(conn, "name")
           ) do
      save_template_response(conn, id, session, topology, template)
    else
      :error -> not_found(conn)
      {:error, :empty_topology} -> rejected(conn, :unprocessable_entity, "empty_topology")
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
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
         {:ok, saved} <- Templates.get(id, template_id),
         {:ok, updated} <-
           Templates.update(id, template_id, template_update_attrs(conn), dry_run: dry_run?(conn)) do
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
           Templates.duplicate(id, template_id, template_duplicate_attrs(conn),
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
         {:ok, saved} <- Templates.get(id, template_id),
         :ok <- Templates.delete(id, template_id) do
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
          {:ok, diff, topology} ->
            json(conn, %{
              action: "template_applied",
              dry_run: true,
              reconcile: true,
              result: template_diff_result(diff),
              diff: diff,
              topology: topology
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
            template_reconcile_mutation_payload(conn, workspace_id, session, template_id, result)
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
          json(conn, template_mutation_payload(conn, workspace_id, session, template_id, result))
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

  defp dry_run_template_diff(workspace_id, session, template_id) do
    case SessionTemplate.get(template_id) do
      {:ok, _built_in} ->
        {:error, :unsupported_reconcile}

      {:error, :template_not_found} ->
        topology = topology_payload(workspace_id, session)

        case Templates.diff(workspace_id, template_id, topology,
               workspace_root: workspace_root_for_export(workspace_id)
             ) do
          {:ok, diff} -> {:ok, diff, topology}
          {:error, _reason} = error -> error
        end
    end
  end

  defp execute_template_reconcile(workspace_id, session, template_id) do
    case SessionTemplate.get(template_id) do
      {:ok, _built_in} ->
        {:error, :unsupported_reconcile}

      {:error, :template_not_found} ->
        with {:ok, root} <- workspace_root(workspace_id) do
          topology = topology_payload(workspace_id, session)

          Templates.execute_reconcile(workspace_id, session, template_id, topology,
            tmux: tmux_adapter(),
            workspace_root: root
          )
        end
    end
  end

  defp dry_run_template(workspace_id, template_id) do
    case SessionTemplate.dry_run(template_id) do
      {:ok, result} ->
        {:ok, result}

      {:error, :template_not_found} ->
        Templates.dry_run(workspace_id, template_id)

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_template(workspace_id, session, template_id, root) do
    opts = [tmux: tmux_adapter(), workspace_root: root]

    case SessionTemplate.execute(session, template_id, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, :template_not_found} ->
        Templates.execute(workspace_id, session, template_id, opts)

      {:error, _reason} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Payloads

  defp template_mutation_payload(conn, workspace_id, session, template_id, result) do
    topology = refreshed_topology_payload(workspace_id, session)
    emit_tmux_template_audit(conn, workspace_id, session, template_id, result, topology)

    %{
      action: "template_applied",
      dry_run: false,
      result: result,
      topology: topology
    }
  end

  defp template_reconcile_mutation_payload(conn, workspace_id, session, template_id, result) do
    topology = refreshed_topology_payload(workspace_id, session)
    execution = Map.put(result.execution, :plan_executed, true)
    emit_tmux_template_audit(conn, workspace_id, session, template_id, execution, topology)

    %{
      action: "template_applied",
      dry_run: false,
      reconcile: true,
      result: execution,
      diff: result.diff,
      summary: result.diff.summary,
      topology: topology
    }
  end

  defp save_template_response(conn, workspace_id, session, topology, template) do
    yaml = DevIDE.Terminals.SessionTemplate.Export.to_yaml(template)

    if dry_run?(conn) do
      json(conn, %{
        action: "template_exported",
        dry_run: true,
        workspace_id: workspace_id,
        session: session,
        template: template,
        yaml: yaml,
        topology: topology_payload(workspace_id, session)
      })
    else
      case Templates.save(%{
             workspace_id: workspace_id,
             name: template["name"],
             description: param(conn, "description"),
             body: template,
             source_session: session,
             schema_version: template["version"] || 2,
             tags: Map.get(conn.params, "tags")
           }) do
        {:ok, saved} ->
          saved_payload = saved_template_detail_payload(saved)
          emit_tmux_template_exported_audit(conn, workspace_id, session, saved, topology)

          conn
          |> put_status(:created)
          |> json(%{
            action: "template_exported",
            dry_run: false,
            workspace_id: workspace_id,
            session: session,
            result: saved_payload,
            saved_template: saved_payload,
            template: template,
            yaml: yaml,
            topology: topology_payload(workspace_id, session)
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          rejected(conn, :unprocessable_entity, changeset_error(changeset))

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
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

  defp built_in_template_payload(%SessionTemplate{} = template) do
    %{
      id: template.id,
      name: template.name,
      description: template.description,
      source: "built_in",
      schema_version: 1,
      apply_supported: true,
      tags: [],
      windows: length(template.windows),
      panes:
        length(template.windows) +
          (template.windows
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
      apply_supported: Templates.apply_supported?(saved),
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

  defp template_source(%{source: source}) when is_binary(source), do: source
  defp template_source(%{"source" => source}) when is_binary(source), do: source
  defp template_source(_template), do: "built_in"

  defp template_schema_version(%{schema_version: version}) when is_integer(version), do: version

  defp template_schema_version(%{"schema_version" => version}) when is_integer(version),
    do: version

  defp template_schema_version(_template), do: 1

  defp template_diff_result(diff) do
    %{
      template: diff.template,
      strategy: diff.strategy,
      step_count: length(diff.changes),
      summary: diff.summary,
      estimated_disruption: diff.estimated_disruption,
      changes: diff.changes
    }
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

  defp emit_tmux_template_audit(_conn, workspace_id, session, template_id, result, topology) do
    template = Map.get(result, :template, %{})

    Audit.emit!(%{
      action: "tmux.template_applied",
      workspace_id: workspace_id,
      actor_id: "api",
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
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_exported_audit(_conn, workspace_id, session, saved, topology) do
    Audit.emit!(%{
      action: "tmux.template_exported",
      workspace_id: workspace_id,
      actor_id: "api",
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
        dry_run: false
      }
    })
  end

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
