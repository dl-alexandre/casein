defmodule DevIDE.FilePanes.Registration do
  @moduledoc """
  Pure registration build, schema→map adapter, full workspace loc resolver,
  and tab/string helpers for file panes. No process state.

  The **full** `workspace_loc/1` (Manager-capable via `Workspaces.get/1`) lives
  here for caller-side paths only (`save_tab`/`reload_tab`/`open_file_in_pane`).
  The in-server broadcast path must use `Payload.workspace_loc_state_only/1`
  (I8) — never this module's `workspace_loc/1`.
  """

  alias DevIDE.FilePanes.FilePaneRegistration
  alias DevIDE.Files.PathSafety
  alias DevIDE.Workspaces

  def build(attrs) do
    pane_id = string_param(attrs, :pane_id)
    workspace_id = string_param(attrs, :workspace_id)

    with {:ok, pane_id} <- require_binary(pane_id, :missing_pane_id),
         {:ok, workspace_id} <- require_binary(workspace_id, :missing_workspace_id) do
      open_files = normalize_open_files(attrs)

      {:ok,
       %{
         id: pane_id,
         pane_id: pane_id,
         workspace_id: workspace_id,
         tmux_session: string_param(attrs, :tmux_session),
         pane_window_id: string_param(attrs, :pane_window_id),
         placement: string_param(attrs, :placement),
         anchor_pane_id: string_param(attrs, :anchor_pane_id),
         anchor_window_id: string_param(attrs, :anchor_window_id),
         open_files: open_files,
         active_path: string_param(attrs, :active_path) || first_path(open_files),
         status: :open
       }}
    end
  end

  def from_persisted(%FilePaneRegistration{} = r) do
    open_files = normalize_open_files(%{open_files: r.open_files})

    %{
      id: r.pane_id,
      pane_id: r.pane_id,
      workspace_id: r.workspace_id,
      tmux_session: r.tmux_session,
      pane_window_id: r.pane_window_id,
      placement: r.placement,
      anchor_pane_id: r.anchor_pane_id,
      anchor_window_id: r.anchor_window_id,
      open_files: open_files,
      active_path: r.active_path || first_path(open_files),
      status: :open
    }
  end

  def normalize_open_files(attrs) do
    (Map.get(attrs, :open_files) || Map.get(attrs, "open_files") || [])
    |> Enum.map(&normalize_tab/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_tab(%{path: path} = tab) when is_binary(path),
    do: %{path: path, line: normalize_line(Map.get(tab, :line))}

  def normalize_tab(%{"path" => path} = tab) when is_binary(path),
    do: %{path: path, line: normalize_line(Map.get(tab, "line"))}

  def normalize_tab(_), do: nil

  def merge_tab(tab, nil), do: tab
  def merge_tab(tab, line), do: %{tab | line: line}

  def normalize_line(line) when is_integer(line) and line > 0, do: line
  def normalize_line(_), do: nil

  def first_path([%{path: path} | _]), do: path
  def first_path(_), do: nil

  def last_path(tabs) do
    case List.last(tabs) do
      %{path: path} -> path
      _ -> nil
    end
  end

  # Full workspace host-loc resolution for CALLER-SIDE file read/write
  # (save_tab/reload_tab). These run in the caller process, not the singleton,
  # so the Manager resolve is fine here — and it is REQUIRED to produce
  # `{:remote, host, path}` locs for remote workspaces (manager.ex:150), which
  # the state-only Payload variant cannot. Do NOT call this from the in-server
  # broadcast path (that uses Payload.workspace_loc_state_only via active_payload).
  def workspace_loc(workspace_id) do
    with {:ok, workspace} <- Workspaces.get(workspace_id),
         {:ok, loc} <- Workspaces.safe_host_loc(workspace) do
      {:ok, loc}
    else
      _ -> {:error, :workspace_not_found}
    end
  end

  def to_rel(loc, path) do
    root = loc_root(loc)

    rel =
      if String.starts_with?(path, "/") do
        Path.relative_to(path, root)
      else
        path
      end

    case PathSafety.resolve(root, rel) do
      {:ok, _abs} -> {:ok, rel}
      {:error, _} = err -> err
    end
  end

  def loc_root({:local, root}), do: root
  def loc_root({:remote, _host, root}), do: root

  def workspace_tmux_session(workspace) do
    Map.get(workspace, :tmux_session) || Map.get(workspace, "tmux_session")
  end

  def workspace_id(%{id: id}) when is_binary(id), do: id
  def workspace_id(%{"id" => id}) when is_binary(id), do: id
  def workspace_id(_), do: nil

  def string_param(attrs, key) when is_atom(key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    case value do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  def require_binary(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  def require_binary(_value, error), do: {:error, error}
end
