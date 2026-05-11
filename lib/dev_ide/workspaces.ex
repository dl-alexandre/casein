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

  def list(opts \\ []) do
    case ManagerClient.list(opts) do
      {:ok, workspaces} = ok ->
        for ws <- workspaces, do: _ = State.sync_from_manager(ws)
        ok

      other ->
        other
    end
  end

  def get(id) do
    case ManagerClient.get(id) do
      {:ok, ws} = ok ->
        _ = State.sync_from_manager(ws)
        ok

      other ->
        other
    end
  end

  defdelegate create(params), to: ManagerClient
  defdelegate start(id), to: ManagerClient
  defdelegate stop(id), to: ManagerClient
  defdelegate delete(id, opts \\ []), to: ManagerClient

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
