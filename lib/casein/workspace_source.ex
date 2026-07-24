defmodule Casein.WorkspaceSource do
  @moduledoc """
  Pluggable backend for workspace discovery and lifecycle.

  The default `Casein.WorkspaceSource.Local` discovers workspaces as
  directories on disk. Production deployments select an integration-specific
  source via config:

      config :casein, :workspace_source, MySource

  Sources implement this behaviour and return `%Casein.Workspace{}` values.
  Source-specific extras belong in `Workspace.metadata`; `Casein.Workspaces`
  is the stable consumer-facing facade.
  """

  alias Casein.Agents.LocalAdapter
  alias Casein.Workspace

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
  @callback prepare_local_argv(argv :: [String.t()], opts :: keyword()) :: [String.t()]

  @doc """
  Optional. Returns a shell command to run inside the tmux pane for a
  `:local` workspace terminal, or `nil` for the default user shell.
  """
  @callback local_tmux_pane_shell() :: String.t() | nil
  @callback local_tmux_pane_shell(host_cwd :: String.t()) :: String.t() | nil

  @doc """
  Optional. Maps a host workspace cwd to the cwd that should be passed to the
  wrapped command. For direct local execution this is the same path; for
  container-backed integrations this may be a mount point or a normal workspace
  path that the wrapper bootstraps inside the container.
  """
  @callback local_exec_cwd(host_cwd :: String.t()) :: String.t()

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
              Casein.Agents.Capability.t()
            ]

  @doc """
  Optional. Returns the list of fields that the "Create workspace" form
  should expose for this source. This keeps devbox/manager-specific fields
  (like `type`) out of the standalone Local experience.
  """
  @callback create_form_fields() :: [atom()]

  @optional_callbacks prepare_local_argv: 1,
                      prepare_local_argv: 2,
                      local_tmux_pane_shell: 0,
                      local_tmux_pane_shell: 1,
                      local_exec_cwd: 1,
                      default_log_service: 1,
                      detect_capabilities: 2,
                      create_form_fields: 0

  @doc """
  Returns the configured workspace source module. Defaults to
  `Casein.WorkspaceSource.Local` — the no-integration, real-directory backend
  that the dev `mix phx.server` flow uses.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)

  @doc "Wrap a local-spawn argv via the configured source, or identity."
  @spec prepare_local_argv([String.t()]) :: [String.t()]
  def prepare_local_argv(argv), do: prepare_local_argv(argv, [])

  @doc """
  Wrap a local-spawn argv with source-specific opts.

  Recognised opts:
    * `:tty` — `true` requests an interactive TTY at the wrapping boundary
      (e.g. drops `docker compose exec -T` so a long-lived TTY program like
      tmux can allocate its controlling terminal). Default `false`.
  """
  @spec prepare_local_argv([String.t()], keyword()) :: [String.t()]
  def prepare_local_argv(argv, opts) when is_list(opts) do
    impl = impl()

    cond do
      exports?(impl, :prepare_local_argv, 2) -> impl.prepare_local_argv(argv, opts)
      exports?(impl, :prepare_local_argv, 1) -> impl.prepare_local_argv(argv)
      true -> argv
    end
  end

  @doc "Tmux pane shell command via the configured source, or nil (default shell)."
  @spec local_tmux_pane_shell() :: String.t() | nil
  def local_tmux_pane_shell do
    impl = impl()

    if exports?(impl, :local_tmux_pane_shell, 0) do
      impl.local_tmux_pane_shell()
    else
      nil
    end
  end

  @doc "Tmux pane shell command via the configured source for a host cwd, or nil."
  @spec local_tmux_pane_shell(String.t()) :: String.t() | nil
  def local_tmux_pane_shell(host_cwd) when is_binary(host_cwd) do
    impl = impl()

    cond do
      exports?(impl, :local_tmux_pane_shell, 1) -> impl.local_tmux_pane_shell(host_cwd)
      exports?(impl, :local_tmux_pane_shell, 0) -> impl.local_tmux_pane_shell()
      true -> nil
    end
  end

  @doc "Map a host workspace cwd to the cwd used inside the local execution wrapper."
  @spec local_exec_cwd(String.t()) :: String.t()
  def local_exec_cwd(host_cwd) when is_binary(host_cwd) do
    impl = impl()

    if exports?(impl, :local_exec_cwd, 1) do
      impl.local_exec_cwd(host_cwd)
    else
      host_cwd
    end
  end

  @doc """
  Returns the default log service for the given workspace according to the
  configured source, or "app" as a safe fallback.
  """
  @spec default_log_service(Workspace.t() | map()) :: String.t()
  def default_log_service(workspace) do
    impl = impl()

    if exports?(impl, :default_log_service, 1) do
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
          Casein.Agents.Capability.t()
        ]
  def detect_capabilities(workspace, root) do
    impl = impl()

    if exports?(impl, :detect_capabilities, 2) do
      impl.detect_capabilities(workspace, root)
    else
      # Direct filesystem detection (avoid calling back into LocalAdapter.detect
      # to prevent recursion during transition)
      LocalAdapter.detect_filesystem_only(root)
    end
  end

  @doc """
  Returns the list of fields the create form should show for the active source.
  Defaults to a minimal `[:name]` for standalone use.
  """
  @spec create_form_fields() :: [atom()]
  def create_form_fields do
    impl = impl()

    if exports?(impl, :create_form_fields, 0) do
      impl.create_form_fields()
    else
      [:name]
    end
  end

  defp exports?(impl, fun, arity) do
    Code.ensure_loaded?(impl) and function_exported?(impl, fun, arity)
  end
end
