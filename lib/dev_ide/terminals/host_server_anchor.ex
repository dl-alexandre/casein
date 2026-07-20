defmodule DevIDE.Terminals.HostServerAnchor do
  @moduledoc """
  Claims the host tmux server (`-L <label>`) from a stable, always-valid working
  directory at boot, before any workspace `Session` can lazily spawn it.

  A tmux server daemon permanently inherits the cwd of the process that first
  starts it, and this daemon outlives BEAM restarts (`KillMode=process`). If a
  `Session` running in a `/tmp/devide-agent-worktrees/...` worktree wins the race
  to be the first tmux call, the daemon's cwd becomes that worktree — which the
  worktree sweep later reaps. After that, every new pane starts in a deleted cwd
  and shells fail with `getcwd: ... No such file or directory` (the 2026-07-09
  devbox incident).

  Creating a detached keepalive session from a fixed cwd during supervisor
  startup (synchronously, before the `Session` DynamicSupervisor and the
  Endpoint) claims the daemon first, pinning its cwd for the process lifetime.
  The session is named `__devide_keepalive` — deliberately NOT the `devide_`
  prefix — so the janitor, MCP `terminal_list_sessions`, and workspace scoping
  all ignore it (they filter on `devide_`). A matching `scripts/devide-tmux.service`
  systemd unit is belt-and-suspenders; same session name keeps them idempotent.
  """

  require Logger

  alias DevIDE.Terminals.TmuxRunner
  alias DevIDE.Terminals.TmuxServer

  @anchor "__devide_keepalive"
  @candidate_dirs ["/opt/devide", "/"]

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
    Application.get_env(:dev_ide, :tmux_host_anchor, true) and is_binary(TmuxServer.label())
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

  # sobelow_skip ["CI.System"]
  defp create_anchor(dir) do
    # `-c dir` sets the session cwd; `cd: dir` on the spawn sets the *daemon's*
    # cwd (the load-bearing part — the server inherits the spawning process's
    # cwd, which is what got poisoned in the incident).
    [cmd | args] = TmuxRunner.host_argv(["new-session", "-d", "-s", @anchor, "-c", dir])

    case System.cmd(cmd, args, cd: dir, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("host tmux anchor started (#{@anchor}) from #{dir}")
        :ok

      {out, code} ->
        Logger.warning("host tmux anchor create failed (exit #{code}): #{String.trim(out)}")
        :error
    end
  end
end
