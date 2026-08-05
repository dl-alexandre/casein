defmodule Casein.Terminals.HostServerAnchor do
  @moduledoc """
  Claims the host tmux server (`-L <label>`) from a stable, always-valid working
  directory at boot, before any workspace `Session` can lazily spawn it.

  A tmux server daemon permanently inherits the cwd of the process that first
  starts it, and this daemon outlives BEAM restarts (`KillMode=process`). If a
  `Session` running in a `/tmp/casein-agent-worktrees/...` worktree wins the race
  to be the first tmux call, the daemon's cwd becomes that worktree — which the
  worktree sweep later reaps. After that, every new pane starts in a deleted cwd
  and shells fail with `getcwd: ... No such file or directory` (the 2026-07-09
  devbox incident).

  Creating a detached keepalive session from a fixed cwd during supervisor
  startup (synchronously, before the `Session` DynamicSupervisor and the
  Endpoint) claims the daemon first, pinning its cwd for the process lifetime.
  The session is named `__casein_keepalive` — deliberately NOT the `casein_`
  prefix — so the janitor, MCP `terminal_list_sessions`, and workspace scoping
  all ignore it (they filter on `casein_`). A matching `scripts/casein-tmux.service`
  systemd unit is belt-and-suspenders; same session name keeps them idempotent.
  """

  require Logger

  alias Casein.Terminals.TmuxRunner
  alias Casein.Terminals.TmuxServer

  @anchor "__casein_keepalive"
  @candidate_dirs ["/opt/casein", "/"]
  @stale_socket_marker "server exited unexpectedly"

  @doc """
  Idempotently ensure the host tmux server is running and rooted at a stable
  cwd. Safe to call at boot: never raises, always returns `:ok`.
  """
  @spec ensure!() :: :ok
  def ensure! do
    if enabled?() do
      dir = stable_dir()

      unless anchor_alive?() do
        create_anchor(dir)
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("host tmux anchor skipped: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("host tmux anchor skipped: #{inspect({kind, reason})}")
      :ok
  end

  @doc "Session name of the keepalive anchor."
  @spec anchor_name() :: String.t()
  def anchor_name, do: @anchor

  # Enabled only when a host server label is configured (no anchor for the
  # default/unlabeled server) and not explicitly disabled — off in :test, and
  # settable off for pure in-container-tmux deployments that have no host server.
  @doc false
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:casein, :tmux_host_anchor, true) and is_binary(TmuxServer.label())
  end

  # Pure: first existing directory among the candidates, then $HOME, then "/".
  # `dir_exists?` is injectable for tests.
  @doc false
  @spec stable_dir([String.t()], (String.t() -> boolean())) :: String.t()
  def stable_dir(candidates \\ @candidate_dirs, dir_exists? \\ &File.dir?/1) do
    home = System.get_env("HOME")

    (candidates ++ [home, "/"])
    |> Enum.find("/", fn d -> is_binary(d) and d != "" and dir_exists?.(d) end)
  end

  # sobelow_skip ["CI.System"]
  defp anchor_alive? do
    [cmd | args] = TmuxRunner.host_argv(["has-session", "-t", @anchor])

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp create_anchor(dir) do
    case spawn_anchor(dir) do
      {_, 0} ->
        Logger.info("host tmux anchor started (#{@anchor}) from #{dir}")
        :ok

      {out, code} ->
        if stale_socket_failure?(out) do
          retry_after_unlink(dir, out, code)
        else
          log_create_failure(out, code)
        end
    end
  end

  # sobelow_skip ["CI.System"]
  defp spawn_anchor(dir) do
    # `-c dir` sets the session cwd; `cd: dir` on the spawn sets the *daemon's*
    # cwd (the load-bearing part — the server inherits the spawning process's
    # cwd, which is what got poisoned in the incident).
    [cmd | args] = TmuxRunner.host_argv(["new-session", "-d", "-s", @anchor, "-c", dir])

    System.cmd(cmd, args, cd: dir, stderr_to_stdout: true)
  end

  # A tmux server that dies without unlinking its socket leaves a file that every
  # subsequent client connects to and is immediately dropped by, so `new-session`
  # keeps failing with `server exited unexpectedly` forever — tmux never clears it
  # itself (the 2026-08-03 devbox outage). Unlinking the orphan lets the next
  # `new-session` bind a fresh socket.
  #
  # Only reachable when `new-session` already failed with that exact message, so
  # there is no reachable server to strand: a healthy one would have succeeded. If
  # a wedged server process is still alive it simply keeps an unlinked inode and
  # stays unreachable, which it already was.
  # socket_path/3 composes TMUX_TMPDIR (operator env), `id -u`, and the app's
  # own TmuxServer.label() — no request- or user-supplied segment reaches it,
  # so there is no traversal source to taint.
  # sobelow_skip ["Traversal.FileModule"]
  defp retry_after_unlink(dir, out, code) do
    with path when is_binary(path) <- socket_path(),
         true <- File.exists?(path),
         :ok <- File.rm(path) do
      Logger.warning("host tmux anchor: unlinked stale socket #{path}; retrying create")

      case spawn_anchor(dir) do
        {_, 0} ->
          Logger.info("host tmux anchor recovered from stale socket (#{@anchor}) from #{dir}")
          :ok

        {retry_out, retry_code} ->
          log_create_failure(retry_out, retry_code)
      end
    else
      _ -> log_create_failure(out, code)
    end
  end

  defp log_create_failure(out, code) do
    Logger.warning("host tmux anchor create failed (exit #{code}): #{String.trim(out)}")
    :error
  end

  @doc """
  True when tmux's `new-session` output is the signature of an orphaned socket
  file left behind by a server that is gone or unreachable.
  """
  @spec stale_socket_failure?(String.t()) :: boolean()
  def stale_socket_failure?(out) when is_binary(out) do
    String.contains?(String.downcase(out), @stale_socket_marker)
  end

  def stale_socket_failure?(_), do: false

  @doc """
  Path tmux uses for the configured server label, or `nil` for the default
  server (whose socket this module must never remove).

  Mirrors tmux's own rule: `$TMUX_TMPDIR` (default `/tmp`) + `tmux-<uid>/<label>`.
  Args are injectable for tests.
  """
  @spec socket_path(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def socket_path(
        label \\ TmuxServer.label(),
        tmpdir \\ System.get_env("TMUX_TMPDIR"),
        uid \\ uid()
      )

  def socket_path(label, tmpdir, uid) when is_binary(label) and label != "" and is_binary(uid) do
    base = if is_binary(tmpdir) and tmpdir != "", do: tmpdir, else: "/tmp"
    Path.join([base, "tmux-#{uid}", label])
  end

  def socket_path(_, _, _), do: nil

  # sobelow_skip ["CI.System"]
  defp uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
