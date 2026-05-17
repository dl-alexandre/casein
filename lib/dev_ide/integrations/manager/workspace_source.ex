defmodule DevIDE.Integrations.Manager.WorkspaceSource do
  @moduledoc """
  `DevIDE.WorkspaceSource` adapter for the milc-devbox manager integration.

  Hides the integration-specific HTTP client, payload shape, and special
  filesystem roots behind the generic source contract. All integration
  knowledge (env vars, manager URL, on-host detection, remote ssh host)
  lives in this module — nowhere else in the application.
  """

  @behaviour DevIDE.WorkspaceSource

  alias DevIDE.Workspace
  alias DevIDE.Integrations.Manager.Client
  alias DevIDE.Integrations.Manager.Workspace, as: ManagerWorkspace

  # Filesystem root used by the integration when DevIDE runs colocated on
  # the integration host (mirrors what the manager mounts).
  @on_host_workspaces_root "/data/workspaces"

  @impl true
  def list(opts \\ [], auth \\ nil) do
    with {:ok, list} <- Client.list(opts, auth) do
      {:ok, Enum.map(list, &to_public/1)}
    end
  end

  @impl true
  def get(id, auth \\ nil) do
    with {:ok, ws} <- Client.get(id, auth) do
      {:ok, to_public(ws)}
    end
  end

  @impl true
  def create(params, auth \\ nil) do
    with {:ok, ws} <- Client.create(params, auth) do
      {:ok, to_public(ws)}
    end
  end

  @impl true
  defdelegate start(id, auth \\ nil), to: Client

  @impl true
  defdelegate stop(id, auth \\ nil), to: Client

  @impl true
  defdelegate delete(id, opts \\ [], auth \\ nil), to: Client

  @impl true
  defdelegate stream_logs(id, service, pid), to: Client

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
  def safe_host_loc(%Workspace{path: nil}), do: {:error, :missing_path}
  def safe_host_loc(%Workspace{path: ""}), do: {:error, :missing_path}

  def safe_host_loc(%Workspace{path: path}) do
    cond do
      on_host?() ->
        expanded = Path.expand(path)

        if under_root?(expanded, @on_host_workspaces_root) do
          {:ok, {:local, expanded}}
        else
          {:error, :outside_root}
        end

      is_binary(remote_ssh_host()) ->
        {:ok, {:remote, remote_ssh_host(), path}}

      true ->
        case safe_host_path(%Workspace{path: path}) do
          {:ok, local} -> {:ok, {:local, local}}
          err -> err
        end
    end
  end

  def safe_host_loc(%{path: path}) when is_binary(path),
    do: safe_host_loc(%Workspace{path: path})

  ## Integration-specific configuration — all env-var reads live here.

  @doc """
  True when DevIDE runs colocated on the integration host. Set via
  `:dev_ide, :on_devbox` or env `DEV_IDE_ON_DEVBOX`.
  """
  @spec on_host?() :: boolean()
  def on_host? do
    case Application.get_env(:dev_ide, :on_devbox) do
      nil -> System.get_env("DEV_IDE_ON_DEVBOX") in ~w(1 true yes)
      val -> !!val
    end
  end

  @doc """
  Compose service to exec into for command/terminal execution in on-host
  mode. Set via `:dev_ide, :devbox_exec_service` or env
  `DEV_IDE_DEVBOX_EXEC_SERVICE`; defaults to `"onebackend-v3"`.
  """
  @spec exec_service() :: String.t()
  def exec_service do
    Application.get_env(:dev_ide, :devbox_exec_service) ||
      System.get_env("DEV_IDE_DEVBOX_EXEC_SERVICE") ||
      "onebackend-v3"
  end

  @doc "SSH host for remote integration workspaces, or nil for local-only mode."
  @spec remote_ssh_host() :: String.t() | nil
  def remote_ssh_host do
    Application.get_env(:dev_ide, :remote_ssh_host) ||
      System.get_env("MILC_DEVBOX_SSH_HOST")
  end

  ## Generic command-shape overrides — called from DevIDE.Workspaces.

  @impl true
  def prepare_local_argv(argv) when is_list(argv) do
    if on_host?() do
      docker_bin = System.find_executable("docker") || "/usr/bin/docker"
      [docker_bin, "compose", "exec", "-T", exec_service() | argv]
    else
      argv
    end
  end

  @impl true
  def local_tmux_pane_shell do
    if on_host?() do
      "docker compose exec #{exec_service()} bash -l"
    end
  end

  ## Internals

  defp to_public(%ManagerWorkspace{} = ws) do
    %Workspace{
      id: ws.id,
      name: ws.name,
      user: ws.user,
      branch: ws.branch,
      status: ws.status,
      path: ws.path,
      metadata: %{
        type: ws.type,
        slot: ws.slot,
        domain_base: ws.domain_base,
        ports: ws.ports,
        created_at: ws.created_at,
        last_started: ws.last_started,
        raw: ws.raw
      }
    }
  end

  defp allowed_roots do
    config = Application.get_env(:dev_ide, :workspaces_roots, [])
    primary = Application.get_env(:dev_ide, :workspaces_root, "/workspaces")
    [primary | config] |> Enum.uniq() |> Enum.map(&Path.expand/1)
  end

  defp under_root?(path, root) do
    rel = Path.relative_to(path, root)
    rel != path and not String.starts_with?(rel, "..")
  end
end
