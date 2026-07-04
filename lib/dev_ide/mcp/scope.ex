defmodule DevIDE.MCP.Scope do
  @moduledoc """
  Resolves MCP tool-call scope for workspace and tmux-session context.

  This module owns argument injection, workspace/session resolution, and basic
  scope enforcement for MCP surfaces. It does not own HTTP auth, rate limiting,
  tool execution, terminal pane/session existence checks, or `tools/list`
  schema shaping.

  `resolved_from` is intentionally returned for debugging, auditing, and future
  policy decisions. Later passes may move more terminal session resolution and
  preview surface identity handling here.
  """

  alias DevIDE.PreviewControl.Registry
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases

  @preview_workspace_tools ~w(
    preview_resolve_workspace
    preview_surfaces
    preview_open
    preview_open_current_workspace
    preview_open_here
    preview_ensure_server_here
    preview_open_app
    preview_open_localhost
    preview_playback_open
    preview_compare_snapshots
    preview_reload_iframe
    preview_observe_pane
    devide_reload_page
  )

  @doc """
  Returns preview tool names that require workspace resolution in `resolve_tool_call/3`.
  """
  @spec preview_workspace_tool_names() :: [String.t()]
  def preview_workspace_tool_names, do: @preview_workspace_tools

  @preview_default_tmux_session_tools ~w(
    preview_open
    preview_open_current_workspace
    preview_surfaces
    preview_open_here
    preview_ensure_server_here
    preview_open_app
    preview_open_localhost
    preview_playback_open
  )

  @type surface :: :preview | :terminal | :artifact

  @type resolved_from :: %{
          workspace: :args | :pre_scoped | :path | :registry | nil,
          tmux_session: :args | :pre_scoped | nil
        }

  @type t :: %{
          args: map(),
          workspace: map(),
          workspace_id: String.t() | nil,
          tmux_session: String.t() | nil,
          surface: surface(),
          resolved_from: resolved_from()
        }

  @spec resolve_tool_call(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def resolve_tool_call(tool_name, args, opts \\ [])

  def resolve_tool_call(tool_name, args, opts)
      when is_binary(tool_name) and is_map(args) and is_list(opts) do
    surface = Keyword.get(opts, :surface)
    default_workspace_id = non_empty(Keyword.get(opts, :default_workspace_id))
    default_tmux_session = non_empty(Keyword.get(opts, :default_tmux_session))

    with {:ok, args, workspace_origin} <- resolve_workspace_args(args, default_workspace_id),
         {:ok, args, tmux_origin} <-
           resolve_tmux_session_args(tool_name, args, default_tmux_session, surface),
         {:ok, workspace, workspace_id, workspace_origin} <-
           resolve_workspace(tool_name, args, surface, workspace_origin),
         :ok <- enforce_workspace_scope(default_workspace_id, workspace_id),
         :ok <- enforce_required_workspace(tool_name, surface, workspace_id, opts),
         :ok <- enforce_required_tmux_session(args, opts) do
      {:ok,
       %{
         args: args,
         workspace: workspace,
         workspace_id: workspace_id,
         tmux_session: tmux_session(args),
         surface: surface,
         resolved_from: %{workspace: workspace_origin, tmux_session: tmux_origin}
       }}
    end
  end

  def resolve_tool_call(_tool_name, _args, _opts), do: {:error, :invalid_tool_arguments}

  defp resolve_workspace_args(args, nil), do: {:ok, args, workspace_arg_origin(args)}

  defp resolve_workspace_args(args, default_workspace_id) do
    case workspace_id(args) do
      nil ->
        {:ok, Map.put(args, "workspace_id", default_workspace_id), :pre_scoped}

      ^default_workspace_id ->
        {:ok, args, :args}

      requested ->
        if WorkspaceAliases.linked?(default_workspace_id, requested) do
          {:ok, args, :args}
        else
          {:error, workspace_scope_mismatch(default_workspace_id, requested)}
        end
    end
  end

  defp resolve_tmux_session_args(tool_name, args, default_tmux_session, :preview)
       when tool_name in @preview_default_tmux_session_tools and is_binary(default_tmux_session) do
    case tmux_session(args) do
      nil -> {:ok, Map.put(args, "tmux_session", default_tmux_session), :pre_scoped}
      ^default_tmux_session -> {:ok, args, :args}
      requested -> {:error, tmux_session_scope_mismatch(default_tmux_session, requested)}
    end
  end

  defp resolve_tmux_session_args(_tool_name, args, _default_tmux_session, _surface) do
    {:ok, args, tmux_session_arg_origin(args)}
  end

  defp resolve_workspace(tool_name, args, :preview, origin)
       when tool_name in @preview_workspace_tools do
    cond do
      id = workspace_id(args) ->
        case Workspaces.get(id) do
          {:ok, workspace} -> {:ok, workspace, id, origin || :args}
          {:error, reason} -> {:error, workspace_id_error(id, reason)}
        end

      path = workspace_path(args) ->
        case Workspaces.attach_folder(path) do
          {:ok, workspace} -> {:ok, workspace, workspace.id, :path}
          {:error, reason} -> {:error, workspace_path_error(path, reason)}
        end

      true ->
        {:error, missing_workspace_id_error()}
    end
  end

  defp resolve_workspace(_tool_name, args, :preview, _origin) do
    case preview_session_workspace_id(args) do
      id when is_binary(id) -> {:ok, %{}, id, :registry}
      _ -> {:ok, %{}, nil, nil}
    end
  end

  defp resolve_workspace(_tool_name, args, _surface, origin) do
    {:ok, %{}, workspace_id(args), origin}
  end

  defp enforce_required_workspace(tool_name, :preview, workspace_id, opts) do
    require_workspace? =
      Keyword.get(opts, :require_workspace?, tool_name in @preview_workspace_tools)

    if require_workspace? and is_nil(workspace_id) do
      {:error, missing_workspace_id_error()}
    else
      :ok
    end
  end

  defp enforce_required_workspace(_tool_name, _surface, workspace_id, opts) do
    if Keyword.get(opts, :require_workspace?, false) and is_nil(workspace_id) do
      {:error, missing_workspace_id_error()}
    else
      :ok
    end
  end

  defp enforce_workspace_scope(nil, _workspace_id), do: :ok
  defp enforce_workspace_scope(_default_workspace_id, nil), do: :ok

  defp enforce_workspace_scope(default_workspace_id, workspace_id) do
    if WorkspaceAliases.linked?(default_workspace_id, workspace_id) do
      :ok
    else
      {:error, workspace_scope_mismatch(default_workspace_id, workspace_id)}
    end
  end

  defp enforce_required_tmux_session(args, opts) do
    if Keyword.get(opts, :require_tmux_session?, false) and is_nil(tmux_session(args)) do
      {:error, :missing_tmux_session}
    else
      :ok
    end
  end

  defp workspace_arg_origin(args) do
    cond do
      workspace_id(args) -> :args
      workspace_path(args) -> :path
      true -> nil
    end
  end

  defp tmux_session_arg_origin(args) do
    if tmux_session(args), do: :args, else: nil
  end

  defp preview_session_workspace_id(%{"session_id" => session_id}) when is_integer(session_id) do
    case Registry.get(session_id) do
      %{preview: %{workspace_id: workspace_id}} -> workspace_id
      _ -> nil
    end
  end

  defp preview_session_workspace_id(%{"session_id" => session_id}) when is_binary(session_id) do
    case Integer.parse(session_id) do
      {id, ""} -> preview_session_workspace_id(%{"session_id" => id})
      _ -> nil
    end
  end

  defp preview_session_workspace_id(%{session_id: session_id}) when is_integer(session_id),
    do: preview_session_workspace_id(%{"session_id" => session_id})

  defp preview_session_workspace_id(_args), do: nil

  defp workspace_id(args) when is_map(args) do
    args
    |> value("workspace_id")
    |> non_empty()
  end

  defp workspace_path(args) when is_map(args) do
    ["workspace_path", "path", "cwd"]
    |> Enum.find_value(fn key -> args |> value(key) |> non_empty() end)
  end

  defp tmux_session(args) when is_map(args) do
    args
    |> value("tmux_session")
    |> non_empty()
  end

  defp value(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp atom_key("workspace_id"), do: :workspace_id
  defp atom_key("workspace_path"), do: :workspace_path
  defp atom_key("path"), do: :path
  defp atom_key("cwd"), do: :cwd
  defp atom_key("tmux_session"), do: :tmux_session
  defp atom_key(_key), do: nil

  defp non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_empty(_), do: nil

  defp missing_workspace_id_error do
    %{
      error: :missing_workspace_id,
      message:
        "Pass workspace_id or workspace_path. Generated DevIDE MCP URLs inject workspace_id automatically.",
      folder_id_format: "folder:<base64url-absolute-path>"
    }
  end

  defp workspace_scope_mismatch(scoped_workspace_id, requested_workspace_id) do
    %{
      error: :workspace_scope_mismatch,
      scoped_workspace_id: scoped_workspace_id,
      requested_workspace_id: requested_workspace_id,
      message:
        "This MCP endpoint is pre-scoped to workspace_id #{inspect(scoped_workspace_id)}. " <>
          "Omit workspace_id on tool calls (it is injected automatically), or use an MCP URL " <>
          "scoped to #{inspect(requested_workspace_id)}. " <>
          "Cannot access #{inspect(requested_workspace_id)} from this endpoint."
    }
  end

  defp workspace_id_error(id, reason) do
    %{
      error: :workspace_not_found,
      workspace_id: id,
      reason: reason,
      message:
        "Workspace #{inspect(id)} was not found. For attached folders, pass workspace_path or use folder:<base64url-absolute-path>.",
      folder_id_format: "folder:<base64url-absolute-path>"
    }
  end

  defp workspace_path_error(path, reason) do
    %{
      error: :workspace_path_not_resolved,
      path: path,
      reason: reason,
      message: "Workspace path #{inspect(path)} could not be attached or is outside allowed roots"
    }
  end

  defp tmux_session_scope_mismatch(scoped_tmux_session, requested_tmux_session) do
    %{
      error: :tmux_session_scope_mismatch,
      scoped_tmux_session: scoped_tmux_session,
      requested_tmux_session: requested_tmux_session,
      message:
        "This Preview MCP endpoint is pre-scoped to tmux_session #{inspect(scoped_tmux_session)}. " <>
          "Omit tmux_session on preview-open calls so it is injected automatically, " <>
          "or use the MCP URL for #{inspect(requested_tmux_session)}."
    }
  end
end
