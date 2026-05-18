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

  @doc """
  Optional. Returns the name of the log service that should be tailed by
  default for this workspace (used by the log/evidence drawer in the UI).
  Returns `nil` or a service name. The caller usually falls back to "app".
  """
  @callback default_log_service(workspace :: Workspace.t() | map()) :: String.t() | nil

  @doc """
  Optional. Returns workspace-specific capabilities (Tidewave, opencode, FFF, etc.)
  for the given workspace and filesystem root. This allows sources to fully
  control what capabilities are advertised without polluting generic code.
  """
  @callback detect_capabilities(workspace :: Workspace.t() | map(), root :: String.t() | nil) :: [
              DevIDE.Agents.Capability.t()
            ]

  @doc """
  Optional. Returns the list of fields that the "Create workspace" form
  should expose for this source. This keeps devbox/manager-specific fields
  (like `type`) out of the standalone Local experience.
  """
  @callback create_form_fields() :: [atom()]

  @optional_callbacks prepare_local_argv: 1,
                      local_tmux_pane_shell: 0,
                      default_log_service: 1,
                      detect_capabilities: 2,
                      create_form_fields: 0

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

  @doc """
  Returns the default log service for the given workspace according to the
  configured source, or "app" as a safe fallback.
  """
  @spec default_log_service(Workspace.t() | map()) :: String.t()
  def default_log_service(workspace) do
    impl = impl()

    if function_exported?(impl, :default_log_service, 1) do
      case impl.default_log_service(workspace) do
        service when is_binary(service) -> service
        _ -> "app"
      end
    else
      "app"
    end
  end

  @doc """
  Returns capabilities for the workspace by delegating to the configured source
  when possible. Falls back to the legacy filesystem detection.
  """
  @spec detect_capabilities(Workspace.t() | map(), String.t() | nil) :: [
          DevIDE.Agents.Capability.t()
        ]
  def detect_capabilities(workspace, root) do
    impl = impl()

    if function_exported?(impl, :detect_capabilities, 2) do
      impl.detect_capabilities(workspace, root)
    else
      # Direct filesystem detection (avoid calling back into LocalAdapter.detect
      # to prevent recursion during transition)
      DevIDE.Agents.LocalAdapter.detect_filesystem_only(root)
    end
  end

  @doc """
  Returns the list of fields the create form should show for the active source.
  Defaults to a minimal `[:name]` for standalone use.
  """
  @spec create_form_fields() :: [atom()]
  def create_form_fields do
    impl = impl()

    if function_exported?(impl, :create_form_fields, 0) do
      impl.create_form_fields()
    else
      [:name]
    end
  end
end
