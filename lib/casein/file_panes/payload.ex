defmodule Casein.FilePanes.Payload do
  @moduledoc """
  Pure payload build + broadcast for file panes. No process state.

  The state-only workspace loc resolver lives here deliberately: it is used
  only by `active_payload/1` (in-server broadcast path), and co-locating it
  structurally enforces I8 — this module does not call `Workspaces.get/1` or
  Manager HTTP, so the in-server path cannot regress to a blocking resolve.
  """

  alias Casein.Panes.Events, as: PaneEvents
  alias Casein.Workspaces
  alias Casein.Workspaces.FileAccess

  @pane_type :file

  def build(reg) do
    %{
      tabs:
        Enum.map(reg.open_files, &%{path: &1.path, title: Path.basename(&1.path), line: &1.line}),
      active_path: reg.active_path,
      active: active_payload(reg),
      workspace_id: reg.workspace_id,
      tmux_session: reg.tmux_session
    }
  end

  # broadcast_after: wrap a GenServer mutation reply, emitting `:updated`.
  def broadcast_after({:ok, reg}) do
    broadcast(:updated, reg)
    {:ok, reg}
  end

  def broadcast_after(other), do: other

  def broadcast(reason, reg) do
    payload = if reason == :removed, do: %{}, else: build(reg)

    PaneEvents.broadcast(%{
      reason: reason,
      type: @pane_type,
      pane_id: reg.pane_id,
      workspace_id: reg.workspace_id,
      tmux_session: reg.tmux_session,
      payload: payload
    })
  end

  defp active_payload(%{active_path: nil}), do: nil

  defp active_payload(%{active_path: path} = reg) do
    line = active_line(reg, path)

    # State-only: this builds the broadcast payload inside the singleton's
    # commit_op — must never block on a Manager HTTP resolve.
    case workspace_loc_state_only(reg.workspace_id) do
      {:ok, loc} ->
        case FileAccess.read_text(loc, path) do
          {:ok, %{content: content, version: version}} ->
            %{path: path, content: content, version: version, line: line}

          {:error, reason} ->
            %{path: path, error: reason, line: line}
        end

      _ ->
        %{path: path, error: :workspace_not_found, line: line}
    end
  end

  defp active_line(reg, path) do
    case Enum.find(reg.open_files, &(&1.path == path)) do
      %{line: line} -> line
      _ -> nil
    end
  end

  # State-only host-loc for the IN-SERVER broadcast payload build only. See
  # active_payload: `broadcast/2` fires in `commit_op` (the singleton), so
  # resolving via `workspace_loc/1` -> `Workspaces.get/1` -> Manager HTTP on a
  # cold `State` cache could hang and back up the singleton mailbox (the
  # broadcast-fan-out cascade root #314 closes for the PreviewPanes twin). Mirror
  # `Aliases.expanded_host_path`: folder-attach id, then the `State` record's
  # host_path, never a remote resolve. Remote/cold-cache workspaces yield
  # `:workspace_not_found` (payload omits active content; the viewer's on-demand
  # hydrate path — which uses the caller-side full resolver — fills it).
  defp workspace_loc_state_only(workspace_id) do
    case state_only_host_path(workspace_id) do
      path when is_binary(path) and path != "" ->
        expanded = Path.expand(path)
        if File.dir?(expanded), do: {:ok, {:local, expanded}}, else: {:error, :not_found}

      _ ->
        {:error, :workspace_not_found}
    end
  end

  defp state_only_host_path(workspace_id) do
    case Workspaces.decode_folder_id(workspace_id) do
      path when is_binary(path) ->
        path

      _ ->
        case Workspaces.State.get(workspace_id) do
          {:ok, %{host_path: path}} when is_binary(path) and path != "" -> path
          _ -> nil
        end
    end
  end
end
