defmodule DevIDE.WorkspaceSource.Local do
  @moduledoc """
  Workspace source that discovers workspaces as subdirectories of a
  configurable root.

  Defaults to `:dev_ide, :workspaces_root` (or `/workspaces`), with the
  workspace's directory name as both `id` and `name`. Status is always
  `:running` (a directory is either present or not — there is no remote
  lifecycle to query). Lifecycle operations (`start`, `stop`) are
  no-ops; `create` makes the directory; `delete` is intentionally
  refused unless `:allow_destructive` is set, to keep the default
  developer experience safe.

  When `:dev_ide, :home_workspace_path` is configured, a synthetic `home`
  workspace points at that exact directory. LAN mode uses this to make the
  default workspace the service user's real home directory without making
  `/home` itself the workspace root.

  This is the unconditional default for `mix phx.server` in dev — no
  external service required.
  """

  @behaviour DevIDE.WorkspaceSource

  alias DevIDE.Workspace
  @home_workspace_name "home"

  @impl true
  def list(_opts \\ [], _auth \\ nil) do
    root = root_path()

    with {:ok, workspaces} <- root_workspaces(root) do
      {:ok,
       workspaces
       |> include_home_workspace()
       |> Enum.uniq_by(& &1.id)
       |> Enum.sort_by(& &1.id)}
    end
  end

  @impl true
  def get(id, _auth \\ nil) when is_binary(id) do
    case home_workspace(id) do
      {:ok, workspace} ->
        {:ok, workspace}

      :not_configured ->
        root = root_path()
        path = Path.join(root, id)

        if File.dir?(path) do
          {:ok, build_workspace(id, root)}
        else
          {:error, :not_found}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl true
  def create(%{"name" => name}, auth), do: create(%{name: name}, auth)

  # name is rejected unless it is a single safe path segment before filesystem use.
  # sobelow_skip ["Traversal.FileModule"]
  def create(%{name: name}, _auth) when is_binary(name) do
    root = root_path()
    target = Path.join(root, name)

    cond do
      not safe_name?(name) ->
        {:error, :invalid_name}

      home_workspace_configured?(name) ->
        {:error, :already_exists}

      File.dir?(target) ->
        {:error, :already_exists}

      true ->
        case File.mkdir_p(target) do
          :ok -> {:ok, build_workspace(name, root)}
          {:error, reason} -> {:error, {:fs, reason}}
        end
    end
  end

  def create(_, _), do: {:error, :invalid_params}

  @impl true
  def start(_id, _auth \\ nil), do: {:ok, :noop}

  @impl true
  def stop(_id, _auth \\ nil), do: {:ok, :noop}

  @impl true
  def delete(id, opts \\ [], _auth \\ nil) when is_binary(id) do
    if home_workspace_configured?(id) do
      {:error, :destructive_not_allowed}
    else
      delete_root_workspace(id, opts)
    end
  end

  # id is rejected unless it is a single safe path segment before destructive use.
  # sobelow_skip ["Traversal.FileModule"]
  defp delete_root_workspace(id, opts) do
    if Keyword.get(opts, :allow_destructive, false) do
      root = root_path()
      target = Path.join(root, id)

      cond do
        not safe_name?(id) ->
          {:error, :invalid_name}

        not File.dir?(target) ->
          {:error, :not_found}

        true ->
          case File.rm_rf(target) do
            {:ok, _} -> {:ok, :deleted}
            {:error, reason, _} -> {:error, {:fs, reason}}
          end
      end
    else
      {:error, :destructive_not_allowed}
    end
  end

  @impl true
  def stream_logs(_id, _service, _pid), do: {:error, :not_supported}

  @impl true
  def default_log_service(_workspace), do: "app"

  @impl true
  def create_form_fields, do: [:name]

  @impl true
  def detect_capabilities(workspace, root) do
    base = DevIDE.WorkspaceSource.capability_detector().detect_filesystem_only(root)

    # Enrich with Tidewave if the workspace provides explicit port info
    metadata = get_metadata(workspace)

    domain_base = metadata_value(metadata, :domain_base)

    tidewave =
      case metadata_value(metadata, :ports) do
        %{"tidewave" => port} when is_integer(port) and is_binary(domain_base) ->
          %DevIDE.Agents.Capability{
            kind: :tidewave,
            status: :detected,
            source: :manager,
            url: "https://tidewave.#{domain_base}",
            details: %{port: port}
          }

        _ ->
          Enum.find(base, &(&1.kind == :tidewave)) || local_tidewave_capability()
      end

    Enum.map(base, fn cap ->
      if cap.kind == :tidewave, do: tidewave, else: cap
    end)
  end

  defp get_metadata(%DevIDE.Workspace{metadata: m}), do: m
  defp get_metadata(%{metadata: m}), do: m
  defp get_metadata(_), do: %{}

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil

  defp local_tidewave_capability, do: DevIDE.Agents.TidewaveCapability.detect()

  @impl true
  def safe_host_path(%Workspace{path: nil}), do: {:error, :missing_path}
  def safe_host_path(%Workspace{path: ""}), do: {:error, :missing_path}

  def safe_host_path(%Workspace{path: path}) do
    expanded = Path.expand(path)

    if Enum.any?(allowed_roots(), &under_root?(expanded, &1)) do
      {:ok, expanded}
    else
      {:error, :outside_root}
    end
  end

  def safe_host_path(%{path: path}) when is_binary(path),
    do: safe_host_path(%Workspace{path: path})

  def safe_host_path(_), do: {:error, :missing_path}

  @impl true
  def safe_host_loc(workspace) do
    case safe_host_path(workspace) do
      {:ok, local} -> {:ok, {:local, local}}
      err -> err
    end
  end

  ## Internals

  defp build_workspace(name, root) do
    path = Path.expand(Path.join(root, name))

    build_workspace_at(name, path, %{})
  end

  defp build_workspace_at(name, path, metadata) do
    %Workspace{
      id: name,
      name: name,
      user: nil,
      branch: detect_branch(path),
      status: :running,
      path: path,
      metadata: metadata
    }
  end

  defp root_workspaces(root) do
    case File.ls(root) do
      {:ok, names} ->
        {:ok,
         names
         |> Enum.filter(&File.dir?(Path.join(root, &1)))
         |> Enum.map(&build_workspace(&1, root))}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:fs, reason}}
    end
  end

  defp include_home_workspace(workspaces) do
    case home_workspace(@home_workspace_name) do
      {:ok, workspace} -> [workspace | workspaces]
      _ -> workspaces
    end
  end

  defp home_workspace(@home_workspace_name) do
    case home_workspace_path() do
      path when is_binary(path) ->
        if File.dir?(path) do
          {:ok, build_workspace_at(@home_workspace_name, path, %{home_workspace: true})}
        else
          :not_found
        end

      nil ->
        :not_configured
    end
  end

  defp home_workspace(_id), do: :not_configured

  defp home_workspace_configured?(@home_workspace_name), do: is_binary(home_workspace_path())
  defp home_workspace_configured?(_name), do: false

  defp detect_branch(path) do
    case System.cmd("git", ["-C", path, "branch", "--show-current"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> nilify_empty()
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp nilify_empty(""), do: nil
  defp nilify_empty(s), do: s

  defp root_path do
    Application.get_env(:dev_ide, :workspaces_root, "/workspaces")
    |> Path.expand()
  end

  defp home_workspace_path do
    case Application.get_env(:dev_ide, :home_workspace_path) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> nil
    end
  end

  defp allowed_roots do
    config = Application.get_env(:dev_ide, :workspaces_roots) || []
    primary = Application.get_env(:dev_ide, :workspaces_root, "/workspaces")
    home = home_workspace_path()

    [primary, home | config]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.map(&Path.expand/1)
  end

  defp under_root?(path, root) do
    rel = Path.relative_to(path, root)
    rel != path and not String.starts_with?(rel, "..")
  end

  defp safe_name?(name) do
    name not in ["", ".", ".."] and not String.contains?(name, "/")
  end
end
