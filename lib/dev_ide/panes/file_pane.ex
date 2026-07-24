defmodule Casein.Panes.FilePane do
  @moduledoc """
  `Casein.Panes.Pane` implementation for file-editor panes.

  Named `FilePane` (not `File`) to avoid shadowing Elixir's `File` at alias sites.
  A thin adapter over `Casein.FilePanes`: it gives the uniform pane pipeline a typed
  entry point into the file-pane registry, so a `:file` leaf in a session template
  is brought to life on execute/reconcile just like a `:preview` leaf.

  ## Node payload

  The template `:command` field is the pane's payload: a shell command for
  `:terminal`, a URL for `:preview`, and the **workspace-relative file path** for
  `:file`. Line numbers are runtime-only and never travel through templates.
  """

  @behaviour Casein.Panes.Pane

  alias Casein.Files.PathSafety
  alias Casein.FilePanes
  alias Casein.Workspaces
  alias Casein.Workspaces.FileAccess

  @impl true
  def attach(node, ctx) do
    with {:ok, pane_id} <- fetch(ctx, :pane_id),
         {:ok, path} <- fetch_payload(node) do
      case FilePanes.get_by_pane(pane_id) do
        %{open_files: files} ->
          if Enum.any?(files, &(&1.path == path)) do
            {:ok, pane_id}
          else
            with {:ok, _reg} <- FilePanes.open_tab(pane_id, path), do: {:ok, pane_id}
          end

        _ ->
          register(pane_id, path, ctx)
      end
    end
  end

  @impl true
  def serialize(pane_id) when is_binary(pane_id) do
    case FilePanes.get_by_pane(pane_id) do
      %{active_path: path} when is_binary(path) ->
        %{"type" => "file", "command" => path}

      _ ->
        %{"type" => "file"}
    end
  end

  @impl true
  def terminate(pane_id) when is_binary(pane_id) do
    _ = FilePanes.deregister(pane_id)
    :ok
  end

  @impl true
  def render_payload(pane_id) when is_binary(pane_id) do
    FilePanes.render_state(pane_id)
  end

  @impl true
  def handle_input(pane_id, %{} = input) when is_binary(pane_id) do
    path = string_field(input, :path)

    case input_type(input) do
      "open_tab" ->
        normalize(FilePanes.open_tab(pane_id, path, line: int_field(input, :line)))

      "activate_tab" ->
        normalize(FilePanes.activate_tab(pane_id, path))

      "close_tab" ->
        normalize(FilePanes.close_tab(pane_id, path))

      "goto_line" ->
        normalize(FilePanes.open_tab(pane_id, path, line: int_field(input, :line)))

      "reload" ->
        normalize(FilePanes.reload_tab(pane_id, path))

      "save" ->
        normalize(
          FilePanes.save_tab(
            pane_id,
            path,
            string_field(input, :content) || "",
            string_field(input, :version)
          )
        )

      _ ->
        {:error, :unsupported_file_input}
    end
  end

  @impl true
  def set_active(pane_id, active?) when is_binary(pane_id) and is_boolean(active?), do: :ok

  @impl true
  def list(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> FilePanes.list_for_workspace()
    |> Enum.map(& &1.pane_id)
  end

  # --- internals ---------------------------------------------------------------

  defp register(pane_id, path, ctx) do
    workspace_id = ctx[:workspace_id] || ctx["workspace_id"]

    with {:ok, loc} <- workspace_loc(workspace_id),
         {:ok, rel} <- to_rel(loc, path),
         {:ok, _preflight} <- FileAccess.read_text(loc, rel) do
      attrs = %{
        pane_id: pane_id,
        workspace_id: workspace_id,
        tmux_session: ctx[:tmux_session] || ctx["tmux_session"],
        pane_window_id: ctx[:pane_window_id] || ctx["pane_window_id"],
        placement: ctx[:placement] || ctx["placement"],
        anchor_pane_id: ctx[:anchor_pane_id] || ctx["anchor_pane_id"],
        anchor_window_id: ctx[:anchor_window_id] || ctx["anchor_window_id"],
        open_files: [%{path: rel, line: nil}],
        active_path: rel
      }

      case FilePanes.register(attrs) do
        {:ok, reg} -> {:ok, reg.pane_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp workspace_loc(workspace_id) when is_binary(workspace_id) do
    with {:ok, workspace} <- Workspaces.get(workspace_id),
         {:ok, loc} <- Workspaces.safe_host_loc(workspace) do
      {:ok, loc}
    else
      _ -> {:error, :workspace_not_found}
    end
  end

  defp workspace_loc(_), do: {:error, :missing_workspace_id}

  defp to_rel(loc, path) do
    root = loc_root(loc)
    rel = if String.starts_with?(path, "/"), do: Path.relative_to(path, root), else: path

    case PathSafety.resolve(root, rel) do
      {:ok, _abs} -> {:ok, rel}
      {:error, _} = err -> err
    end
  end

  defp loc_root({:local, root}), do: root
  defp loc_root({:remote, _host, root}), do: root

  defp fetch(ctx, key) do
    case ctx[key] || ctx[to_string(key)] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp fetch_payload(node) do
    case node_field(node, :command) || node_field(node, :path) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_file_path}
    end
  end

  defp node_field(node, key) when is_map(node) do
    Map.get(node, key, Map.get(node, to_string(key)))
  end

  defp input_type(input), do: string_field(input, :type)

  defp string_field(input, key) do
    case input[key] || input[to_string(key)] do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp int_field(input, key) do
    case input[key] || input[to_string(key)] do
      v when is_integer(v) ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, reason}), do: {:error, reason}
end
