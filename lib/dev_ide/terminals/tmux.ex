defmodule DevIDE.Terminals.Tmux do
  @moduledoc """
  tmux adapter for workspace terminals.

  Sessions are named `devide_<workspace>_<sid>`. On hosts where the configured
  workspace source wraps argv (e.g. the milc-devbox manager integration: docker
  compose exec into the workspace container), the tmux server itself runs
  *inside* that wrapping — so the session's lifecycle is bound to the
  manager-owned container, not to the dev_ide host. See
  `DevIDE.WorkspaceSource.prepare_local_argv/2` and
  `docs/runtime_orchestration_plan.md` for the ownership story.

  Sessions persist across browser disconnects; LiveViews attach via
  `pipe-pane` ports.
  """

  alias DevIDE.WorkspaceSource

  @session_prefix "devide"

  def session_name(workspace_name, sid) do
    "#{@session_prefix}_#{sanitize(workspace_name)}_#{sanitize(sid)}"
  end

  @doc """
  Probe whether `tmux` is available inside the wrapped (container) context
  for `cwd`. Cached in `:persistent_term` per cwd — Session.init uses it to
  decide between the in-container tmux server (preferred) and the legacy
  host-tmux fallback for workspace images that don't yet ship tmux.

  Returns `true` when:
    * the configured WorkspaceSource does not wrap argv (no container hop —
      tmux is wherever the host has it), or
    * the wrapped probe finds tmux in the container.

  Returns `false` only when the wrap is active AND the container's tmux is
  missing — in which case Session.build_cmd falls back to host tmux.
  """
  def container_has_tmux?(cwd) do
    key = {__MODULE__, :container_tmux, cwd}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        result = probe_container_tmux(cwd)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp probe_container_tmux(cwd) do
    probe_argv =
      WorkspaceSource.prepare_local_argv(["sh", "-c", "command -v tmux >/dev/null 2>&1"])

    case probe_argv do
      ["sh" | _] ->
        # No wrapping configured — host shell, host tmux assumed.
        true

      [cmd | args] ->
        case System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true) do
          {_, 0} ->
            true

          {out, code} ->
            require Logger

            Logger.info(
              "container at #{cwd} lacks tmux (exit=#{code}, out=#{inspect(String.slice(out, 0, 200))}); " <>
                "Terminals.Session will fall back to host tmux"
            )

            false
        end
    end
  rescue
    e ->
      require Logger

      Logger.warning(
        "container tmux probe failed at #{cwd}: #{Exception.message(e)}; assuming absent"
      )

      false
  end

  def ensure_session(session, cwd) do
    case run(["has-session", "-t", session]) do
      {_, 0} ->
        :ok

      _ ->
        case run(["new-session", "-d", "-s", session, "-c", cwd]) do
          {_, 0} -> :ok
          {out, code} -> {:error, {code, out}}
        end
    end
  end

  @doc """
  Opens a Port that streams session output to the calling process and accepts
  keystrokes via `Port.command/2`. Returns `{:ok, port}`.

  When the workspace source wraps argv (on-host docker exec), the Port runs
  the wrapping binary (e.g. docker) with `attach-session` as a downstream arg
  so the attaching client lives inside the container alongside the server.
  """
  def attach(session) do
    [cmd | args] = WorkspaceSource.prepare_local_argv(["tmux", "attach-session", "-t", session])

    port =
      Port.open({:spawn_executable, System.find_executable(cmd) || cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    {:ok, port}
  end

  def send_keys(session, keys) do
    run(["send-keys", "-t", session, keys])
  end

  def kill(session) do
    kill(session, 10)
  end

  @doc """
  Returns true if a tmux session by this name is currently registered with
  the tmux server. Used by Session.init to decide whether to capture
  scrollback before attaching.
  """
  def session_exists?(session) do
    case run(["has-session", "-t", session]) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Apply dev_ide's standard tmux options to the named session.

  Bundles the set of `set-option` calls that give operators a sane
  default UX without depending on a host-side `~/.tmux.conf`:

    * `mouse on` — click to focus pane, drag splitters, scroll history
    * `escape-time 0` (server) — no 500ms Esc delay; vim/nvim feel instant
    * `history-limit 50000` — survive long build/test output (≈ 5MB/pane max)
    * `focus-events on` — nvim/lazygit etc. see terminal focus changes
    * `allow-passthrough on` — DCS sequences (image protocols, OSC52) pass through
    * `set-clipboard on` (server) — OSC 52 to host clipboard (`"+y` in nvim works)
    * `terminal-overrides ",xterm-256color:Tc"` (append) — truecolor for themes
    * `renumber-windows on` — close a window, no gap in numbering

  Idempotent. Run after every `:terminal_ready` — cheap (~50ms total),
  and re-applying is safe.

  Returns `:ok` if every option succeeded; `{:error, list}` with the
  failed options otherwise. Best-effort: partial success is logged but
  the pane still works without the rest.
  """
  def apply_defaults(session) when is_binary(session) do
    # `-g` = global session option, `-s` = server option, `-ga` = append,
    # `-w` (or `-gw`) = window option.
    options = [
      {["set-option", "-t", session, "-g", "mouse", "on"], "mouse"},
      {["set-option", "-s", "escape-time", "0"], "escape-time"},
      {["set-option", "-t", session, "-g", "history-limit", "50000"], "history-limit"},
      {["set-option", "-t", session, "-g", "focus-events", "on"], "focus-events"},
      {["set-option", "-t", session, "-g", "allow-passthrough", "on"], "allow-passthrough"},
      {["set-option", "-s", "set-clipboard", "on"], "set-clipboard"},
      {["set-option", "-ga", "terminal-overrides", ",xterm-256color:Tc"], "terminal-overrides"},
      {["set-option", "-t", session, "-g", "renumber-windows", "on"], "renumber-windows"},
      # window-size + aggressive-resize make tmux follow the *current* client's
      # TTY size as it changes. Without these, tmux keeps the pane size from
      # session creation — subsequent browser resizes fire SIGWINCH through to
      # tmux but tmux ignores them, so the rendered cell grid stays the wrong
      # shape and the operator sees content cut off / overflowing.
      {["set-option", "-t", session, "-g", "window-size", "latest"], "window-size"},
      {["set-window-option", "-t", session, "-g", "aggressive-resize", "on"], "aggressive-resize"}
    ]

    failures =
      for {args, name} <- options,
          {out, code} = System.cmd("tmux", args, stderr_to_stdout: true),
          code != 0 do
        {name, code, String.slice(out, 0, 120)}
      end

    case failures do
      [] ->
        :ok

      _ ->
        require Logger
        Logger.warning("tmux apply_defaults partial failure for #{session}: #{inspect(failures)}")
        {:error, failures}
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  @doc """
  Send `cmd` followed by Enter to the named tmux session.

  Operator clicks an interactive-agent button (claude / grok / opencode
  etc.) in governed mode → we want to launch the agent in the existing
  tmux session that the raw pane is attached to (or will be attached to
  once they switch to raw). tmux send-keys writes to the pane's stdin
  regardless of whether anything is attached, so this works as a
  governed→raw bridge.

  Host-direct invocation (same rationale as resize_window/3).

  Returns `:ok` on success; System.cmd result tuple otherwise. Fails
  silently with non-zero exit if the session doesn't exist yet — caller
  should put_flash a friendly error in that case.
  """
  def send_command(session, cmd) when is_binary(session) and is_binary(cmd) do
    case System.cmd("tmux", ["send-keys", "-t", session, cmd, "Enter"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      other -> other
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  @doc """
  Force tmux to resize the named session's window to `cols × rows`.

  PTY-driven resize (Ghostty.PTY.resize → ioctl TIOCSWINSZ → SIGWINCH on the
  attached tmux client) should be enough, but with `tmux new-session -A`
  re-attaching to a session that survives BEAM/page-reload cycles, tmux's
  `window-size` policy sometimes pins the pane to the *old* client's size and
  doesn't grow to match the new client. Calling `tmux resize-window`
  explicitly overrides that policy.

  Returns `:ok` on success; logs and returns the System.cmd result tuple on
  failure (this is a best-effort sync — the operator gets a usable pane
  either way).
  """
  def resize_window(session, cols, rows)
      when is_binary(session) and is_integer(cols) and is_integer(rows) do
    # Sessions named `devide_*` live wherever PaneWorker / Terminals.Session
    # spawned tmux. In container-tmux mode that's inside the workspace
    # container; in host-tmux fallback mode (current devbox state — workspace
    # images don't ship tmux) it's on the host. We can't reliably know which
    # without per-session state, but the failure mode is asymmetric: targeting
    # host tmux for a container-side session means "session not found" (no-op,
    # the PTY-driven SIGWINCH still resized it). Targeting container tmux when
    # tmux isn't there means exit 127. Host-direct is the safer default for
    # this best-effort resize.
    case System.cmd(
           "tmux",
           ["resize-window", "-t", session, "-x", to_string(cols), "-y", to_string(rows)],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      other -> other
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  @doc """
  Capture the full scrollback of a tmux session's first window/pane, with
  escape sequences preserved (`-e`) and wrapped lines joined (`-J`).
  Returns an empty binary on failure or when the session does not exist —
  the caller seeds an output buffer with the result, so soft-fail is the
  right shape.

  Used to recover pane history when a Session GenServer is re-created
  against an existing tmux session (server restart, replay path).
  """
  def capture_scrollback(session) do
    case run(["capture-pane", "-p", "-e", "-J", "-S", "-", "-t", session]) do
      {output, 0} -> output
      _ -> <<>>
    end
  end

  # Wrap a tmux argv via the configured workspace source and exec it via
  # System.cmd. When the source wraps (e.g. docker exec into the workspace
  # container), the tmux client/server runs inside the container; otherwise
  # tmux runs directly on the host. `-T` is fine here — every caller is a
  # one-shot tmux subcommand (no interactive TTY needed).
  defp run(tmux_args) do
    [cmd | args] = WorkspaceSource.prepare_local_argv(["tmux" | tmux_args])
    System.cmd(cmd, args, stderr_to_stdout: true)
  end

  defp sanitize(s) do
    s
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_\-]/, "_")
    |> String.slice(0, 64)
  end

  defp kill(session, attempts) do
    result = run(["kill-session", "-t", session])

    cond do
      attempts <= 1 ->
        result

      session_exists?(session) ->
        Process.sleep(50)
        kill(session, attempts - 1)

      true ->
        Process.sleep(50)

        if session_exists?(session) do
          kill(session, attempts - 1)
        else
          result
        end
    end
  end
end
