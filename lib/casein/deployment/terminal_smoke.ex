defmodule Casein.Deployment.TerminalSmoke do
  @moduledoc """
  Post-deploy acceptance smoke for the terminal subsystem.

  Application health (`Casein.Deployment.Health`) and the deploy script's MCP
  `tools/list` gate both pass even when a freshly-opened terminal is unusable —
  which is exactly how the 2026-07-09 `getcwd failed` incident shipped: the host
  tmux server's cwd was a reaped worktree, so every new pane started in a deleted
  directory, but every wiring check was green.

  This smoke actually exercises a terminal against the running release: it opens a
  throwaway host tmux session and asserts (a) the tmux **server's own cwd** is a
  live directory — the precise incident signal — and (b) the new session's pane
  starts in a directory that exists. Run pre-swap in the deploy script so a
  failure aborts promotion with the old instance still serving.
  """

  require Logger

  alias Casein.Terminals.TmuxServer

  @session_prefix "casein_smoke_"

  @doc """
  Run the terminal smoke. Returns `:ok` when a fresh terminal is usable, or
  `{:error, reason}` on a definitive failure. Own-bug/infra errors fail open
  (logged, `:ok`) so a smoke hiccup never blocks an otherwise-good deploy; the
  signals we key on (deleted server cwd, missing pane cwd) are unambiguous.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(_opts \\ []) do
    session = @session_prefix <> Integer.to_string(System.unique_integer([:positive]))
    cwd = smoke_cwd()

    try do
      with :ok <- create_session(session, cwd),
           {:ok, server_pid} <- server_pid(session),
           :ok <- check_server_cwd(server_pid) do
        check_pane_cwd(session)
      end
    after
      _ = kill_session(session)
    end
  rescue
    e ->
      Logger.warning("terminal smoke errored (failing open): #{Exception.message(e)}")
      :ok
  end

  # ── pure, testable helpers ──────────────────────────────────────────────────

  @doc """
  True when process `pid`'s working directory is a live directory.

  Detected via the `/proc/<pid>/cwd` symlink target: the Linux kernel appends
  `" (deleted)"` when the process's cwd has been unlinked (the incident — the dir
  is gone but its inode is held open, so `File.stat`/`File.dir?` still succeed;
  only `getcwd(3)` in a real shell fails). Fails open (returns true) when the
  link can't be read — non-Linux dev hosts or a process that already exited — so
  only a present process with a deleted cwd reads as unhealthy. `read_link_fn` is
  injectable for tests.
  """
  @spec proc_cwd_alive?(integer(), (Path.t() -> {:ok, String.t()} | {:error, term()})) ::
          boolean()
  def proc_cwd_alive?(pid, read_link_fn \\ &File.read_link/1) when is_integer(pid) do
    case read_link_fn.("/proc/#{pid}/cwd") do
      {:ok, target} -> not String.ends_with?(target, " (deleted)")
      _ -> true
    end
  end

  @doc "True when the pane's current path exists. `dir_exists?` is injectable."
  @spec pane_cwd_alive?(String.t() | nil, (Path.t() -> boolean())) :: boolean()
  def pane_cwd_alive?(path, dir_exists? \\ &File.dir?/1)

  def pane_cwd_alive?(path, dir_exists?) when is_binary(path) and path != "",
    do: dir_exists?.(path)

  def pane_cwd_alive?(_path, _dir_exists?), do: false

  # ── side-effecting steps ────────────────────────────────────────────────────

  defp create_session(session, cwd) do
    case TmuxCtl.Client.ensure_session(session, cwd) do
      :ok -> :ok
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  end

  # sobelow_skip ["CI.System"]
  defp server_pid(session) do
    case System.cmd(
           "tmux",
           TmuxServer.args() ++ ["display-message", "-p", "-t", session, "\#{pid}"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {pid, _} -> {:ok, pid}
          :error -> {:error, {:server_pid_unparsable, String.trim(out)}}
        end

      {out, code} ->
        {:error, {:server_pid_failed, code, String.trim(out)}}
    end
  end

  defp check_server_cwd(server_pid) do
    if proc_cwd_alive?(server_pid) do
      :ok
    else
      target =
        case File.read_link("/proc/#{server_pid}/cwd") do
          {:ok, t} -> t
          _ -> "unknown"
        end

      {:error, {:tmux_server_cwd_deleted, target}}
    end
  end

  defp check_pane_cwd(session) do
    path =
      session
      |> TmuxCtl.Client.list_session_panes()
      |> List.first()
      |> case do
        %{current_path: p} -> p
        _ -> nil
      end

    if pane_cwd_alive?(path), do: :ok, else: {:error, {:pane_cwd_missing, path}}
  end

  defp kill_session(session) do
    TmuxCtl.Client.kill(session)
  rescue
    _ -> :ok
  end

  # First existing of $HOME, /tmp, / — the smoke only needs a valid -c; the point
  # is to inspect the server cwd, not this path.
  defp smoke_cwd do
    [System.get_env("HOME"), "/tmp", "/"]
    |> Enum.find("/", fn d -> is_binary(d) and d != "" and File.dir?(d) end)
  end
end
