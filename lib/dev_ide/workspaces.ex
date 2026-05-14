defmodule DevIDE.Workspaces do
  @moduledoc """
  Workspaces context. Thin wrapper over the milc-devbox manager API.

  Manager is the source of truth for lifecycle and state. This module exists so
  LiveViews and other consumers depend on a stable Elixir API rather than HTTP
  details, and so the manager response shape is normalized into
  `DevIDE.Devbox.Workspace` structs.
  """

  alias DevIDE.Devbox.{ManagerClient, Workspace}
  alias DevIDE.Workspaces.State

  @workspaces_root_default "/workspaces"

  # When DevIDE runs on the devbox host itself, manager workspaces live here.
  @devbox_workspaces_root "/data/workspaces"

  @typedoc """
  Forward-auth identity to scope a manager request to. An email string is
  forwarded so the manager attributes/filters by that user; `nil` uses the
  static config fallback. See `DevIDE.Devbox.ManagerClient`.
  """
  @type auth :: String.t() | nil

  def list(opts \\ [], auth \\ nil) do
    case ManagerClient.list(opts, auth) do
      {:ok, workspaces} = ok ->
        for ws <- workspaces, do: _ = State.sync_from_manager(ws)
        ok

      other ->
        other
    end
  end

  def get(id, auth \\ nil) do
    case ManagerClient.get(id, auth) do
      {:ok, ws} = ok ->
        _ = State.sync_from_manager(ws)
        ok

      other ->
        other
    end
  end

  defdelegate create(params, auth \\ nil), to: ManagerClient
  defdelegate start(id, auth \\ nil), to: ManagerClient
  defdelegate stop(id, auth \\ nil), to: ManagerClient
  defdelegate delete(id, opts \\ [], auth \\ nil), to: ManagerClient

  @doc """
  True when `username` owns `workspace` — the manager attributes every
  workspace to a `user` (the email local part; see `ForwardAuth`). A pure
  comparison; callers decide *whether* to enforce it (forward-auth on).
  """
  @spec owns?(Workspace.t() | map(), String.t()) :: boolean()
  def owns?(%{user: ws_user}, username) when is_binary(ws_user) and is_binary(username),
    do: ws_user == username

  def owns?(_, _), do: false

  def stream_logs(id, service, pid \\ self()),
    do: ManagerClient.stream_logs(id, service, pid)

  @doc """
  Returns `{:ok, path}` if the workspace path is set and inside an allowed root.

  Defaults to `/workspaces` plus the host-specific root from config:
      config :dev_ide, :workspaces_root, "/workspaces"
  """
  @spec safe_host_path(Workspace.t() | map()) ::
          {:ok, String.t()} | {:error, :missing_path | :outside_root}
  def safe_host_path(%Workspace{path: nil}), do: {:error, :missing_path}
  def safe_host_path(%Workspace{path: ""}), do: {:error, :missing_path}

  def safe_host_path(%Workspace{path: path}) do
    expanded = Path.expand(path)
    roots = allowed_roots()

    if Enum.any?(roots, &under_root?(expanded, &1)) do
      {:ok, expanded}
    else
      {:error, :outside_root}
    end
  end

  def safe_host_path(%{} = map), do: safe_host_path(Workspace.from_payload(map))

  @typedoc "Where a workspace physically lives."
  @type workspace_loc :: {:local, String.t()} | {:remote, String.t(), String.t()}

  @doc """
  Returns the workspace's physical location, distinguishing local from remote.

  Resolution order:

    * `on_devbox?/0` — DevIDE runs on the devbox host; manager workspaces are
      local under `/data/workspaces`. Returns `{:local, path}`, guarded against
      that root rather than `allowed_roots/0`.
    * `:dev_ide, :remote_ssh_host` (or env `MILC_DEVBOX_SSH_HOST`) — every
      manager workspace is remote at that ssh host. The path is *not* checked
      against `allowed_roots/0`; that guard only applies to local file ops.
    * otherwise — local, checked against `allowed_roots/0`.
  """
  @spec safe_host_loc(Workspace.t() | map()) ::
          {:ok, workspace_loc()} | {:error, :missing_path | :outside_root}
  def safe_host_loc(%Workspace{path: nil}), do: {:error, :missing_path}
  def safe_host_loc(%Workspace{path: ""}), do: {:error, :missing_path}

  def safe_host_loc(%Workspace{path: path}) do
    cond do
      on_devbox?() ->
        expanded = Path.expand(path)

        if under_root?(expanded, @devbox_workspaces_root) do
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

  def safe_host_loc(%{} = map), do: safe_host_loc(Workspace.from_payload(map))

  @doc "SSH host for remote workspaces, or nil for local-only mode."
  @spec remote_ssh_host() :: String.t() | nil
  def remote_ssh_host do
    Application.get_env(:dev_ide, :remote_ssh_host) ||
      System.get_env("MILC_DEVBOX_SSH_HOST")
  end

  @doc """
  True when DevIDE runs on the devbox host itself — manager workspaces are on
  the local filesystem and command/terminal execution goes through local
  `docker` rather than ssh. Set via `:dev_ide, :on_devbox` or env
  `DEV_IDE_ON_DEVBOX`.
  """
  @spec on_devbox?() :: boolean()
  def on_devbox? do
    case Application.get_env(:dev_ide, :on_devbox) do
      nil -> System.get_env("DEV_IDE_ON_DEVBOX") in ~w(1 true yes)
      val -> !!val
    end
  end

  @doc """
  Compose service to exec into for command/terminal execution in on-devbox
  mode. Set via `:dev_ide, :devbox_exec_service` or env
  `DEV_IDE_DEVBOX_EXEC_SERVICE`; defaults to `"onebackend-v3"`.
  """
  @spec devbox_exec_service() :: String.t()
  def devbox_exec_service do
    Application.get_env(:dev_ide, :devbox_exec_service) ||
      System.get_env("DEV_IDE_DEVBOX_EXEC_SERVICE") ||
      "onebackend-v3"
  end

  def allowed_roots do
    config = Application.get_env(:dev_ide, :workspaces_roots, [])
    primary = Application.get_env(:dev_ide, :workspaces_root, @workspaces_root_default)

    [primary | config]
    |> Enum.uniq()
    |> Enum.map(&Path.expand/1)
  end

  defp under_root?(path, root) do
    rel = Path.relative_to(path, root)
    rel != path and not String.starts_with?(rel, "..")
  end
end
