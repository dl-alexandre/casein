defmodule CaseinWeb.API.WorkspaceAPI do
  @moduledoc """
  Shared helpers for the workspace API controllers.

  `WorkspaceController` (core/runs), `WorkspaceTemplateController`,
  `WorkspaceWindowController`, and `WorkspacePaneController` all operate on
  the same workspace/tmux surface and share parameter parsing, topology
  snapshots, path safety, and JSON error responses. Import this module to
  get those helpers.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  alias Casein.Files.PathSafety
  alias Casein.Terminals
  alias Casein.Terminals.WindowTrash
  alias Casein.Workspaces

  # ---------------------------------------------------------------------------
  # Responses

  def not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  def rejected(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: to_string(reason)})
  end

  def changeset_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  # ---------------------------------------------------------------------------
  # Params

  def param(conn, key) do
    case Map.get(conn.params, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  def string_param(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  def required_trimmed_param(conn, key, error) do
    case param(conn, key) do
      nil -> {:error, error}
      "" -> {:error, error}
      value -> {:ok, value}
    end
  end

  def string_list_param(map, key) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  def int_param(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def dry_run?(conn) do
    Map.get(conn.params, "dry_run") in [true, "true", "1"]
  end

  def reconcile?(conn) do
    Map.get(conn.params, "reconcile") in [true, "true", "1"]
  end

  # ---------------------------------------------------------------------------
  # Topology

  def topology_session(conn) do
    case param(conn, "session") || param(conn, "tmux_session") do
      nil -> {:error, "session_required"}
      "" -> {:error, "session_required"}
      session -> validate_topology_session(conn, session)
    end
  end

  def topology_payload(workspace_id, session) do
    topology = Terminals.tmux_topology_snapshot(session)

    # Windows closed through the undoable path are still alive in tmux during
    # their grace period, but they are gone as far as callers are concerned —
    # including the response to the DELETE that just closed one. Filtering here
    # keeps every API topology agreeing with what the viewer shows.
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

  @doc """
  Re-register and refresh the topology after a mutation, then snapshot it.
  Every mutating endpoint reports the post-mutation topology this way.
  """
  def refreshed_topology_payload(workspace_id, session) do
    _ = Terminals.configure_tmux_topology(session, workspace_id: workspace_id)
    _ = Terminals.refresh_tmux_topology(session)
    topology_payload(workspace_id, session)
  end

  def optional_topology_payload(conn, workspace_id) do
    case param(conn, "session") || param(conn, "tmux_session") do
      nil ->
        nil

      "" ->
        nil

      session ->
        if Terminals.tmux_session_in_workspace?(session, workspace_id) do
          topology_payload(workspace_id, session)
        end
    end
  end

  # A window pending an undoable close is deliberately invisible here, so
  # selecting or renaming one reports `window_not_found` rather than acting on
  # something the caller has already been told is gone.
  def find_window(session, window_id) do
    session
    |> Terminals.tmux_topology_snapshot()
    |> Map.fetch!(:windows)
    |> then(&WindowTrash.reject_pending(session, &1))
    |> Enum.find(&(&1.id == window_id or to_string(&1.index) == window_id))
  end

  def find_pane(session, pane_id) do
    session
    |> Terminals.tmux_topology_snapshot()
    |> Map.fetch!(:panes)
    |> Enum.find(&(&1.id == pane_id or to_string(&1.index) == pane_id))
  end

  def tmux_adapter do
    Terminals.tmux_adapter()
  end

  defp validate_topology_session(conn, session) do
    workspace_id = param(conn, "id")

    if Terminals.tmux_session_in_workspace?(session, workspace_id) do
      {:ok, session}
    else
      {:error, "invalid_tmux_session_scope"}
    end
  end

  # ---------------------------------------------------------------------------
  # Workspace paths

  def resolve_workspace_path(_workspace_id, nil), do: {:ok, nil}
  def resolve_workspace_path(_workspace_id, ""), do: {:ok, nil}

  def resolve_workspace_path(workspace_id, path) do
    with {:ok, %{host_path: root}} when is_binary(root) <- Workspaces.get_record(workspace_id),
         {:ok, resolved} <- PathSafety.resolve(root, path) do
      {:ok, resolved}
    else
      :error -> {:error, :workspace_root_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  def workspace_root(workspace_id) do
    case Workspaces.get_record(workspace_id) do
      {:ok, %{host_path: root}} when is_binary(root) -> {:ok, root}
      {:ok, _} -> {:error, :workspace_root_unavailable}
      :error -> {:error, :workspace_root_unavailable}
    end
  end

  def workspace_root_for_export(workspace_id) do
    case workspace_root(workspace_id) do
      {:ok, root} -> root
      {:error, _reason} -> nil
    end
  end

  def maybe_put_opt(opts, _key, nil), do: opts
  def maybe_put_opt(opts, _key, ""), do: opts
  def maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
