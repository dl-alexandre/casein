defmodule DevIDE.WorkspaceSource do
  @moduledoc """
  Pluggable backend for workspace discovery and lifecycle.

  The default `DevIDE.WorkspaceSource.Local` discovers workspaces as
  directories on disk. Production deployments select an integration-specific
  source via config:

      config :dev_ide, :workspace_source, MySource

  Sources implement this behaviour and return `%DevIDE.Workspace{}` values.
  Source-specific extras belong in `Workspace.metadata`; `DevIDE.Workspaces`
  is the stable consumer-facing facade.
  """

  alias DevIDE.Workspace

  @type auth :: String.t() | nil
  @type id :: String.t()
  @type error :: term()

  @callback list(opts :: keyword(), auth()) :: {:ok, [Workspace.t()]} | {:error, error()}
  @callback get(id(), auth()) :: {:ok, Workspace.t()} | {:error, error()}
  @callback create(params :: map(), auth()) :: {:ok, Workspace.t()} | {:error, error()}
  @callback start(id(), auth()) :: {:ok, term()} | {:error, error()}
  @callback stop(id(), auth()) :: {:ok, term()} | {:error, error()}
  @callback delete(id(), opts :: keyword(), auth()) :: {:ok, term()} | {:error, error()}
  @callback stream_logs(id(), service :: String.t(), pid()) ::
              {:ok, reference(), term()} | {:error, error()}
  @callback safe_host_path(Workspace.t() | map()) ::
              {:ok, String.t()} | {:error, atom()}
  @callback safe_host_loc(Workspace.t() | map()) ::
              {:ok, {:local, String.t()} | {:remote, String.t(), String.t()}}
              | {:error, atom()}

  @doc """
  Optional. Wraps the argv that runs for a `:local` workspace command.
  Defaults to identity (run argv directly). An integration that runs
  commands inside a container can prepend its own wrapper here without
  the generic command runner having to know.
  """
  @callback prepare_local_argv(argv :: [String.t()]) :: [String.t()]

  @doc """
  Optional. Returns a shell command to run inside the tmux pane for a
  `:local` workspace terminal, or `nil` for the default user shell.
  """
  @callback local_tmux_pane_shell() :: String.t() | nil

  @optional_callbacks prepare_local_argv: 1, local_tmux_pane_shell: 0

  @doc """
  Returns the configured workspace source module. Defaults to
  `DevIDE.WorkspaceSource.Local` — the no-integration, real-directory backend
  that the dev `mix phx.server` flow uses.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local)

  @doc "Wrap a local-spawn argv via the configured source, or identity."
  @spec prepare_local_argv([String.t()]) :: [String.t()]
  def prepare_local_argv(argv) do
    impl = impl()

    if function_exported?(impl, :prepare_local_argv, 1) do
      impl.prepare_local_argv(argv)
    else
      argv
    end
  end

  @doc "Tmux pane shell command via the configured source, or nil (default shell)."
  @spec local_tmux_pane_shell() :: String.t() | nil
  def local_tmux_pane_shell do
    impl = impl()

    if function_exported?(impl, :local_tmux_pane_shell, 0) do
      impl.local_tmux_pane_shell()
    else
      nil
    end
  end
end
