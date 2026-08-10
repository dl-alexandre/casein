defmodule Casein.Terminals.Backends.Tmux do
  @moduledoc """
  Platform-neutral terminal backend backed by the existing tmux facade.

  Keeping this wrapper separate avoids coupling the product behaviour to the
  lower-level `TmuxCtl.Adapter` contract and gives future native backends a
  clean peer module.

  Runtime session ops honor `:tmux_adapter` so existing test fakes keep working
  while product code migrates from direct `Casein.Terminals.Tmux` calls to
  `Casein.Terminals.Backend.module/0`. Session naming stays on `Tmux`/`TmuxPolicy`
  (not part of the swappable adapter contract).
  """

  @behaviour Casein.Terminals.Backend

  alias Casein.Terminals.Backend.SpawnSpec
  alias Casein.Terminals.CleanExec
  alias Casein.Terminals.Shims
  alias Casein.Terminals.Theme
  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxRunner
  alias Casein.Terminals.TmuxServer

  @impl true
  def session_name(workspace_name, sid), do: Tmux.session_name(workspace_name, sid)

  @impl true
  def spawn_spec({:local, cwd}, session) do
    exec_cwd = Casein.WorkspaceSource.local_exec_cwd(cwd)
    host_cwd = safe_local_cwd(cwd)
    theme_opts = [scheme: Theme.default_scheme(), preset: Theme.default_preset_id()]

    new_session_args = fn opts, session_cwd ->
      ["new-session", "-A"] ++
        Shims.tmux_env_flags(opts) ++ ["-s", session, "-c", session_cwd]
    end

    host_argv = fn extra ->
      TmuxRunner.host_argv(new_session_args.(theme_opts, host_cwd) ++ extra)
    end

    container_argv = fn extra ->
      [
        "tmux"
        | new_session_args.(Keyword.put(theme_opts, :include_path?, false), exec_cwd) ++ extra
      ]
    end

    integrated_shell = [login_shell_command()]

    argv =
      cond do
        Tmux.host_shell?() ->
          host_argv.(integrated_shell)

        Tmux.local_argv_wrapped?() and Tmux.container_has_tmux?(cwd) ->
          Casein.WorkspaceSource.prepare_local_argv(container_argv.(integrated_shell),
            tty: true,
            cwd: cwd,
            normal_cwd: exec_cwd
          )

        true ->
          case Casein.WorkspaceSource.local_tmux_pane_shell(cwd) do
            nil -> host_argv.(integrated_shell)
            shell -> host_argv.([shell])
          end
      end

    command =
      argv
      |> CleanExec.wrap_argv()
      |> resolve_executable()
      |> Enum.map(&to_charlist/1)

    {:ok, %SpawnSpec{command: command, exec_opts: [{:cd, to_charlist(host_cwd)}]}}
  end

  def spawn_spec({:remote, host, path}, session) do
    # Always use the labeled Casein tmux server on the remote (issue #556).
    # Label matches local isolation (casein / casein_dev / casein_test) so
    # native `tmux -L <label> attach` sees the same sessions and the host's
    # default tmux server is never touched.
    #
    # Config path is the user-scoped bootstrap target (`~/.casein/tmux/casein.conf`
    # via scripts/bootstrap-remote-tmux.sh). tmux only reads `-f` when *starting*
    # a server; once live the flag is ignored. We still pass it so a first
    # remote spawn after bootstrap (or after a server death) recreates with
    # Casein defaults rather than empty label defaults.
    remote =
      "cd #{shell_quote(path)} && exec tmux #{remote_tmux_global_flags()}new-session -A -s #{session}"

    command =
      ~c"ssh -tt -o BatchMode=yes -o ServerAliveInterval=30 -o ConnectTimeout=10 #{host} -- #{shell_quote(remote)}"

    {:ok, %SpawnSpec{command: command}}
  end

  def spawn_spec(loc, _session), do: {:error, {:unsupported_location, loc}}

  @doc false
  @spec safe_local_cwd(term(), (String.t() -> boolean())) :: String.t()
  def safe_local_cwd(cwd, dir_exists? \\ &File.dir?/1) do
    home = System.get_env("HOME")

    cond do
      is_binary(cwd) and dir_exists?.(cwd) -> cwd
      is_binary(home) and home != "" and dir_exists?.(home) -> home
      true -> "/"
    end
  end

  @impl true
  def ensure_session(session, cwd), do: adapter().ensure_session(session, cwd)

  @impl true
  def attach(session), do: adapter().attach(session)

  @impl true
  def session_exists?(session), do: adapter().session_exists?(session)

  @doc """
  Adapter-compatible existence check with optional `cwd:` (container tmux).

  Not a Backend callback — product recovery paths that already pass `cwd`
  call this on the Tmux backend module when available.
  """
  def session_exists?(session, opts) when is_list(opts) do
    mod = adapter()

    if function_exported?(mod, :session_exists?, 2) do
      mod.session_exists?(session, opts)
    else
      mod.session_exists?(session)
    end
  end

  @impl true
  def session_alive?(session), do: adapter().session_alive?(session)

  @impl true
  def kill(session), do: adapter().kill(session)

  @impl true
  def send_keys(session, keys, opts), do: adapter().send_keys(session, keys, opts)

  @impl true
  def capture_recent(session, lines, opts), do: adapter().capture_recent(session, lines, opts)

  @impl true
  def capture_scrollback(session, opts), do: adapter().capture_scrollback(session, opts)

  @impl true
  def resize_window(session, cols, rows), do: adapter().resize_window(session, cols, rows)

  @impl true
  def window_size(session), do: adapter().window_size(session)

  @impl true
  def list_session_windows(session), do: adapter().list_session_windows(session)

  @impl true
  def list_session_panes(session), do: adapter().list_session_panes(session)

  @impl true
  def session_topology(session), do: adapter().session_topology(session)

  @impl true
  def new_window(session, opts), do: adapter().new_window(session, opts)

  @impl true
  def select_window(session, window_id), do: adapter().select_window(session, window_id)

  @impl true
  def kill_window(session, window_id), do: adapter().kill_window(session, window_id)

  @impl true
  def split_pane(session, pane_id, direction, opts),
    do: adapter().split_pane(session, pane_id, direction, opts)

  @impl true
  def select_pane(session, pane_id), do: adapter().select_pane(session, pane_id)

  @impl true
  def kill_pane(session, pane_id), do: adapter().kill_pane(session, pane_id)

  @impl true
  def resize_pane(session, pane_id, direction, amount),
    do: adapter().resize_pane(session, pane_id, direction, amount)

  @impl true
  def set_pane_role(session, pane_id, role), do: adapter().set_pane_role(session, pane_id, role)

  # --- Adapter-forwarded ops not yet on Casein.Terminals.Backend -------------
  # Product paths (template executors, MCP shared, deploy smoke) call these on
  # Backend.module() so they ride `:tmux_adapter` / future native peers without
  # hard-coding `Casein.Terminals.Tmux` or `TmuxCtl.Client`.

  @doc "Send a shell command to a session/pane via the configured adapter."
  def send_command(session, cmd, opts \\ [])

  def send_command(session, cmd, opts)
      when is_binary(session) and is_binary(cmd) and is_list(opts) do
    adapter().send_command(session, cmd, opts)
  end

  @doc "Set one tmux session environment variable via the configured adapter."
  def set_environment(session, key, value)
      when is_binary(session) and is_binary(key) and is_binary(value) do
    adapter().set_environment(session, key, value)
  end

  @doc "List live sessions via the configured adapter."
  def list_sessions, do: adapter().list_sessions()

  @doc "Workspace session prefix (naming policy; not adapter-swappable)."
  def workspace_session_prefix(workspace_name) when is_binary(workspace_name) do
    Tmux.workspace_session_prefix(workspace_name)
  end

  defp adapter do
    Application.get_env(:casein, :tmux_adapter, Tmux)
  end

  defp login_shell_command do
    Application.get_env(:casein, :tmux_login_shell_command) ||
      System.get_env("CASEIN_TMUX_LOGIN_SHELL") ||
      Shims.shell_command()
  end

  # Space-terminated global flags for embedding in a remote shell command
  # (e.g. "-L casein -f ~/.casein/tmux/casein.conf "). Empty when no label
  # is configured (default server — avoid on shared hosts).
  defp remote_tmux_global_flags do
    label_args =
      case TmuxServer.args() do
        [] -> []
        args -> args
      end

    conf_args =
      case remote_tmux_config_path() do
        path when is_binary(path) and path != "" -> ["-f", path]
        _ -> []
      end

    case label_args ++ conf_args do
      [] -> ""
      args -> Enum.join(args, " ") <> " "
    end
  end

  # User-scoped conf written by scripts/bootstrap-remote-tmux.sh. Expandable
  # on the remote shell (`~` / `$HOME`). Override with :tmux_remote_config_file
  # or CASEIN_TMUX_REMOTE_CONFIG when a remote uses a non-default layout.
  defp remote_tmux_config_path do
    [
      Application.get_env(:casein, :tmux_remote_config_file),
      System.get_env("CASEIN_TMUX_REMOTE_CONFIG"),
      "~/.casein/tmux/casein.conf"
    ]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp resolve_executable([command | rest]) when is_binary(command) do
    [executable_path(command) | rest]
  end

  defp resolve_executable(argv), do: argv

  defp executable_path(command) do
    cond do
      String.contains?(command, "/") -> command
      path = System.find_executable(command) -> path
      true -> command
    end
  end
end
