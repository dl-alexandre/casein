defmodule Casein.Terminals.Backends.Tmux do
  @moduledoc """
  Platform-neutral terminal backend backed by the existing tmux facade.

  Keeping this wrapper separate avoids coupling the product behaviour to the
  lower-level `TmuxCtl.Adapter` contract and gives future native backends a
  clean peer module.
  """

  @behaviour Casein.Terminals.Backend

  alias Casein.Terminals.Backend.SpawnSpec
  alias Casein.Terminals.CleanExec
  alias Casein.Terminals.Shims
  alias Casein.Terminals.Theme
  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxRunner

  @impl true
  defdelegate session_name(workspace_name, sid), to: Tmux

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
    remote = "cd #{shell_quote(path)} && exec tmux new-session -A -s #{session}"

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
  defdelegate ensure_session(session, cwd), to: Tmux
  @impl true
  defdelegate attach(session), to: Tmux
  @impl true
  defdelegate session_exists?(session), to: Tmux
  @impl true
  defdelegate session_alive?(session), to: Tmux
  @impl true
  defdelegate kill(session), to: Tmux
  @impl true
  defdelegate send_keys(session, keys, opts), to: Tmux
  @impl true
  defdelegate capture_recent(session, lines, opts), to: Tmux
  @impl true
  defdelegate capture_scrollback(session, opts), to: Tmux
  @impl true
  defdelegate resize_window(session, cols, rows), to: Tmux
  @impl true
  defdelegate window_size(session), to: Tmux
  @impl true
  defdelegate list_session_windows(session), to: Tmux
  @impl true
  defdelegate list_session_panes(session), to: Tmux
  @impl true
  defdelegate session_topology(session), to: Tmux
  @impl true
  defdelegate new_window(session, opts), to: Tmux
  @impl true
  defdelegate select_window(session, window_id), to: Tmux
  @impl true
  defdelegate kill_window(session, window_id), to: Tmux
  @impl true
  defdelegate split_pane(session, pane_id, direction, opts), to: Tmux
  @impl true
  defdelegate select_pane(session, pane_id), to: Tmux
  @impl true
  defdelegate kill_pane(session, pane_id), to: Tmux
  @impl true
  defdelegate resize_pane(session, pane_id, direction, amount), to: Tmux
  @impl true
  defdelegate set_pane_role(session, pane_id, role), to: Tmux

  defp login_shell_command do
    Application.get_env(:casein, :tmux_login_shell_command) ||
      System.get_env("DEV_IDE_TMUX_LOGIN_SHELL") ||
      Shims.shell_command()
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
