defmodule DevIdeWeb.API.WorkspacePaneController do
  @moduledoc """
  Tmux pane mutations for a workspace: create (split), select, split,
  resize, kill.

  Split out of `WorkspaceController` — same URLs (`/api/workspaces/:id/panes*`),
  same payload shapes. Every mutation refreshes the topology, emits a
  `tmux.pane_*` audit event, and returns the post-mutation topology.
  """

  use DevIdeWeb, :controller

  import DevIdeWeb.API.WorkspaceAPI

  alias DevIDE.Audit
  alias DevIDE.Export
  alias DevIDE.Terminals

  def create_pane(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, pane_id} <- pane_target_param(conn),
         {:ok, direction} <- pane_split_direction(conn) do
      split_pane_mutation(conn, id, session, pane_id, direction)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def select_pane(conn, %{"id" => id, "pane_id" => pane_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_pane(conn, id, session, "pane_selected", fn ->
        case find_pane(session, pane_id) do
          nil -> {:error, :pane_not_found}
          %{active: true} -> :ok
          _pane -> Terminals.select_tmux_pane(session, pane_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def split_pane(conn, %{"id" => id, "pane_id" => pane_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, direction} <- pane_split_direction(conn) do
      split_pane_mutation(conn, id, session, pane_id, direction)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def resize_pane(conn, %{"id" => id, "pane_id" => pane_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, direction} <- pane_resize_direction(conn),
         {:ok, amount} <- pane_resize_amount(conn) do
      mutate_pane(conn, id, session, "pane_resized", fn ->
        case find_pane(session, pane_id) do
          nil -> {:error, :pane_not_found}
          _pane -> Terminals.resize_tmux_pane(session, pane_id, direction, amount)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def kill_pane(conn, %{"id" => id, "pane_id" => pane_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_pane(conn, id, session, "pane_killed", fn ->
        case find_pane(session, pane_id) do
          nil -> {:error, :pane_not_found}
          _pane -> Terminals.kill_tmux_pane(session, pane_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  defp mutate_pane(conn, workspace_id, session, action, fun) do
    if dry_run?(conn) do
      json(conn, %{
        action: action,
        dry_run: true,
        topology: topology_payload(workspace_id, session)
      })
    else
      case fun.() do
        :ok ->
          json(conn, pane_mutation_payload(conn, workspace_id, session, action))

        {:ok, pane_id} ->
          json(
            conn,
            pane_mutation_payload(conn, workspace_id, session, action, %{pane_id: pane_id})
          )

        {:error, :pane_not_found} ->
          rejected(conn, :not_found, "pane_not_found")

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    end
  end

  defp split_pane_mutation(conn, workspace_id, session, pane_id, direction) do
    mutate_pane(conn, workspace_id, session, "pane_split", fn ->
      case find_pane(session, pane_id) do
        nil -> {:error, :pane_not_found}
        _pane -> Terminals.split_tmux_pane(session, pane_id, direction)
      end
    end)
  end

  defp pane_mutation_payload(conn, workspace_id, session, action, result \\ %{}) do
    topology = refreshed_topology_payload(workspace_id, session)
    emit_tmux_pane_audit(conn, workspace_id, session, action, result, topology)

    %{
      action: action,
      dry_run: false,
      result: result,
      topology: topology
    }
  end

  defp pane_target_param(conn) do
    case param(conn, "pane_id") || param(conn, "target_pane_id") do
      nil -> {:error, "pane_id_required"}
      "" -> {:error, "pane_id_required"}
      value -> {:ok, value}
    end
  end

  defp pane_split_direction(conn) do
    case param(conn, "direction") do
      direction when direction in ["h", "v"] -> {:ok, direction}
      _ -> {:error, :invalid_direction}
    end
  end

  defp pane_resize_direction(conn) do
    case param(conn, "direction") do
      direction when direction in ["left", "right", "up", "down"] -> {:ok, direction}
      _ -> {:error, :invalid_direction}
    end
  end

  defp pane_resize_amount(conn) do
    case Map.get(conn.params, "amount") do
      nil -> {:ok, Terminals.tmux_resize_amount_default()}
      value -> parse_resize_amount(value)
    end
  end

  defp parse_resize_amount(value) when is_integer(value), do: validate_resize_amount(value)

  defp parse_resize_amount(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {amount, ""} -> validate_resize_amount(amount)
      _ -> {:error, :invalid_amount}
    end
  end

  defp parse_resize_amount(_), do: {:error, :invalid_amount}

  defp validate_resize_amount(value) when is_integer(value) and value > 0 do
    if value <= Terminals.tmux_resize_amount_max() do
      {:ok, value}
    else
      {:error, :invalid_amount}
    end
  end

  defp validate_resize_amount(_), do: {:error, :invalid_amount}

  defp emit_tmux_pane_audit(conn, workspace_id, session, action, result, topology) do
    pane_id =
      Map.get(result, :pane_id) ||
        Map.get(result, "pane_id") ||
        param(conn, "pane_id") ||
        topology.active_pane_id

    Audit.emit!(%{
      action: "tmux." <> action,
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_pane",
      target_ref: pane_id,
      metadata: %{
        session: session,
        pane_id: pane_id,
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        dry_run: false
      }
    })
  end
end
