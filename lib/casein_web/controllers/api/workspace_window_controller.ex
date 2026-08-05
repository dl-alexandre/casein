defmodule CaseinWeb.API.WorkspaceWindowController do
  @moduledoc """
  Tmux window mutations for a workspace: create, select, rename, close, restore.

  Split out of `WorkspaceController` — same URLs (`/api/workspaces/:id/windows*`),
  same payload shapes. Every mutation refreshes the topology, emits a
  `tmux.window_*` audit event, and returns the post-mutation topology.

  `DELETE /windows/:window_id` is deferred and undoable, the same as closing a
  window in the viewer: it hides the window and arms the real `kill-window` on
  a grace-period timer (`Casein.Terminals.WindowTrash`), reporting `grace_ms`.
  `POST /windows/:window_id/restore` takes that back while it is still pending.
  Trashed windows are filtered out of every topology payload, so a caller never
  sees a window it has been told is closed.
  """

  use CaseinWeb, :controller

  import CaseinWeb.API.WorkspaceAPI

  alias Casein.Audit
  alias Casein.Export
  alias Casein.Terminals.WindowTrash

  # Root every action in a fresh correlation context so the tmux.window_* audit
  # events these mutations emit are traced (Casein.Signals.EntryContext is the
  # LiveView analog; MCP tool calls get the same in each *_mcp.ex call_tool/3).
  def action(conn, _opts) do
    Casein.Signals.Context.with_new(fn ->
      apply(__MODULE__, action_name(conn), [conn, conn.params])
    end)
  end

  def create_window(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, opts} <- window_create_opts(conn, id) do
      mutate_window(conn, id, session, "window_created", fn ->
        tmux_adapter().new_window(session, opts)
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def select_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_window(conn, id, session, "window_selected", fn ->
        case find_window(session, window_id) do
          nil -> {:error, :window_not_found}
          _window -> tmux_adapter().select_window(session, window_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def rename_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, name} <- required_trimmed_param(conn, "name", "name_required") do
      mutate_window(conn, id, session, "window_renamed", fn ->
        case find_window(session, window_id) do
          nil -> {:error, :window_not_found}
          %{name: ^name} -> :ok
          _window -> tmux_adapter().rename_window(session, window_id, name)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  @doc """
  Closes a window — deferred and undoable, matching the viewer.

  The window is hidden from every topology read (including this response) and
  the real `kill-window` is armed on a grace-period timer. Until it fires the
  window and its processes are untouched, so `restore_window/2` can bring it
  back. The response carries `grace_ms` so a caller knows how long it has.
  """
  def kill_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_window(conn, id, session, "window_close_deferred", fn ->
        case find_window(session, window_id) do
          nil ->
            {:error, :window_not_found}

          window ->
            case WindowTrash.trash(session, window.id, Map.get(window, :name)) do
              {:ok, grace_ms} -> {:ok, %{window_id: window.id, grace_ms: grace_ms}}
              {:error, reason} -> {:error, reason}
            end
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  @doc """
  Takes back a deferred close while it is still within its grace period.

  Without this the API's deferral would be a delay with no way to cancel —
  worse for a caller than closing immediately. Returns `window_not_pending`
  once the timer has fired and the window is really gone.
  """
  def restore_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_window(conn, id, session, "window_close_undone", fn ->
        case WindowTrash.restore(session, window_id) do
          {:ok, _name} -> {:ok, %{window_id: window_id}}
          {:error, :not_pending} -> {:error, :window_not_pending}
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  defp mutate_window(conn, workspace_id, session, action, fun) do
    if dry_run?(conn) do
      json(conn, %{
        action: action,
        dry_run: true,
        topology: topology_payload(workspace_id, session)
      })
    else
      case fun.() do
        :ok ->
          json(conn, mutation_payload(conn, workspace_id, session, action))

        # Deferred close/restore report a map so the response can carry
        # grace_ms alongside the window id.
        {:ok, result} when is_map(result) ->
          json(conn, mutation_payload(conn, workspace_id, session, action, result))

        {:ok, window_id} ->
          json(
            conn,
            mutation_payload(conn, workspace_id, session, action, %{window_id: window_id})
          )

        {:error, :window_not_found} ->
          rejected(conn, :not_found, "window_not_found")

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    end
  end

  defp mutation_payload(conn, workspace_id, session, action, result \\ %{}) do
    topology = refreshed_topology_payload(workspace_id, session)
    emit_tmux_window_audit(conn, workspace_id, session, action, result, topology)

    %{
      action: action,
      dry_run: false,
      result: result,
      topology: topology
    }
  end

  defp window_create_opts(conn, workspace_id) do
    with {:ok, cwd} <- resolve_workspace_path(workspace_id, param(conn, "cwd")) do
      {:ok,
       []
       |> maybe_put_opt(:name, param(conn, "name"))
       |> maybe_put_opt(:cwd, cwd)}
    end
  end

  defp emit_tmux_window_audit(conn, workspace_id, session, action, result, topology) do
    window_id =
      Map.get(result, :window_id) ||
        Map.get(result, "window_id") ||
        param(conn, "window_id") ||
        topology.active_window_id

    Audit.emit!(%{
      action: "tmux." <> action,
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_window",
      target_ref: window_id,
      metadata: %{
        session: session,
        window_id: window_id,
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        dry_run: false
      }
    })
  end
end
