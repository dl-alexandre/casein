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
  live directory — the precise incident signal — (b) the new session's pane
  starts in a directory that exists, and (c) a `CASEIN_*` variable pushed into
  the session env *after* the pane exists actually reaches the pane's shell.

  (c) covers the 2026-08-03 incident: `tmux set-environment` only seeds panes
  created after the call, so every pane's shell kept the tmux server's launch
  env — no `CASEIN_WORKSPACE_ID` / MCP URLs, and the global admin API token.
  Every agent launcher refused to start, while the session env table, MCP
  `tools/list`, and app health were all green. Note that `/proc/<pid>/environ`
  cannot see this: it reports the exec-time environment and never reflects a
  later `export`, so the probe has to ask the shell itself.

  Run pre-swap in the deploy script so a failure aborts promotion with the old
  instance still serving.
  """

  require Logger

  alias Casein.Terminals.Backend
  alias Casein.Terminals.TmuxServer

  @session_prefix "casein_smoke_"
  @pairing_var "CASEIN_SMOKE_PAIRING"
  @pairing_marker "casein-pairing"
  @pairing_attempts 8
  @pairing_sleep_ms 400

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
           :ok <- check_server_cwd(server_pid),
           :ok <- check_pane_cwd(session) do
        check_pane_env_pairing(session)
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

  @doc """
  Classify a pane capture taken after probing for the pairing variable.

  The probe prints `casein-pairing=<value>` on its own; the *typed* command line
  is also in the capture, so the marker and the `=` are printf-joined rather
  than literal in the command — otherwise the echoed command would match itself.

  `:hydrated` wins over `:missing` because the capture is cumulative: the first
  probe legitimately prints `MISSING` (the shell hydrates on its *next* prompt,
  which has not happened yet), and that line stays on screen after a later probe
  succeeds.
  """
  @spec pairing_verdict(String.t(), String.t()) :: :hydrated | :missing | :unknown
  def pairing_verdict(capture, nonce) when is_binary(capture) and is_binary(nonce) do
    cond do
      String.contains?(capture, "#{@pairing_marker}=#{nonce}") -> :hydrated
      String.contains?(capture, "#{@pairing_marker}=MISSING") -> :missing
      true -> :unknown
    end
  end

  @doc """
  Shell command that prints the pairing variable under the capture marker.

  Built with printf's format arguments so the literal `#{@pairing_marker}=`
  never appears in the typed command — only in its output.
  """
  @spec pairing_probe() :: String.t()
  def pairing_probe do
    ~s|printf '%s%s\\n' '#{@pairing_marker}' "=${#{@pairing_var}:-MISSING}"|
  end

  # ── side-effecting steps ────────────────────────────────────────────────────

  defp create_session(session, cwd) do
    case backend().ensure_session(session, cwd) do
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
      |> backend().list_session_panes()
      |> List.first()
      |> case do
        %{current_path: p} -> p
        _ -> nil
      end

    if pane_cwd_alive?(path), do: :ok, else: {:error, {:pane_cwd_missing, path}}
  end

  # Set the variable AFTER the pane exists — that ordering is the whole point:
  # it is what PaneEnv.ensure_for_session/3 does, and what a plain
  # `tmux set-environment` cannot deliver to an already-running shell on its own.
  defp check_pane_env_pairing(session) do
    nonce = "#{@pairing_marker}-#{System.unique_integer([:positive])}"

    case backend().set_environment(session, @pairing_var, nonce) do
      :ok ->
        await_pairing(session, nonce, @pairing_attempts)

      other ->
        # Can't even set the session env — infra, not a pairing regression.
        Logger.warning("terminal smoke: set-environment failed (failing open): #{inspect(other)}")
        :ok
    end
  end

  defp await_pairing(_session, _nonce, 0), do: {:error, {:pane_env_not_hydrated, @pairing_var}}

  defp await_pairing(session, nonce, attempts) do
    _ = backend().send_command(session, pairing_probe())
    Process.sleep(@pairing_sleep_ms)

    case backend().capture_recent(session, 40, []) do
      {:ok, capture} ->
        case pairing_verdict(capture, nonce) do
          :hydrated ->
            :ok

          # The first probe is expected to miss: the shell hydrates on its next
          # prompt, which has not run yet. Only a miss that survives the whole
          # window is a regression.
          _ when attempts > 1 ->
            await_pairing(session, nonce, attempts - 1)

          :missing ->
            {:error, {:pane_env_not_hydrated, @pairing_var}}

          :unknown ->
            # Probe output never appeared at all — capture/plumbing problem
            # rather than an env regression.
            Logger.warning("terminal smoke: pairing probe produced no output (failing open)")
            :ok
        end

      other ->
        Logger.warning("terminal smoke: capture failed (failing open): #{inspect(other)}")
        :ok
    end
  end

  defp kill_session(session) do
    backend().kill(session)
  rescue
    _ -> :ok
  end

  defp backend, do: Backend.module()

  # First existing of $HOME, /tmp, / — the smoke only needs a valid -c; the point
  # is to inspect the server cwd, not this path.
  defp smoke_cwd do
    [System.get_env("HOME"), "/tmp", "/"]
    |> Enum.find("/", fn d -> is_binary(d) and d != "" and File.dir?(d) end)
  end
end
