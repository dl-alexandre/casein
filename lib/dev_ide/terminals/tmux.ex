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
  @resize_amount_default 5
  @resize_amount_max 50

  def host_shell? do
    Application.get_env(:dev_ide, :tmux_host_shell) ||
      System.get_env("DEV_IDE_TMUX_HOST_SHELL") in ~w(1 true yes)
  end

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
        # Only cache positive results. A false/error result may be transient
        # (container not yet started, docker exec race, probe failure) — caching
        # false permanently would break raw terminals for the lifetime of the
        # BEAM even after the container comes up. Negative results are re-probed
        # on the next attempt, which is cheap (one System.cmd) and correct.
        if result, do: :persistent_term.put(key, true)
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
    e in [ErlangError, File.Error] ->
      require Logger

      Logger.warning(
        "container tmux probe failed at #{cwd}: #{Exception.message(e)}; assuming absent"
      )

      false
  end

  def ensure_session(session, cwd) do
    case run(["has-session", "-t", session]) do
      {_, 0} ->
        _ = apply_defaults(session)
        :ok

      _ ->
        case run(["new-session", "-d", "-s", session, "-c", cwd]) do
          {_, 0} ->
            _ = apply_defaults(session)
            :ok

          {out, code} ->
            {:error, {code, out}}
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
    [cmd | args] = tmux_argv(["attach-session", "-t", session])

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

  @topology_window_fmt ~S(#{window_id}|#{window_index}|#{window_name}|#{window_active}|#{window_panes}|#{window_activity}|#{pane_current_command})
  @topology_pane_fmt ~S(#{window_id}|#{pane_id}|#{pane_index}|#{pane_active}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_current_command}|#{pane_activity}|#{pane_bell}|#{window_activity}|#{window_activity_flag}|#{window_bell_flag}|#{pane_unseen_changes}|#{pane_current_path})

  @doc """
  List windows for one tmux session, returning maps suitable for UI topology.
  """
  @spec list_session_windows(String.t()) :: [map()]
  def list_session_windows(session) when is_binary(session) do
    case run(["list-windows", "-t", session, "-F", @topology_window_fmt]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_topology_window_line/1)

      _ ->
        []
    end
  end

  defp parse_topology_window_line(line) do
    case String.split(line, "|", parts: 7) do
      [id, index, name, active, panes, activity, current_command] ->
        [
          %{
            id: id,
            index: parse_int(index, 0),
            name: name,
            active: active == "1",
            panes: parse_int(panes, 1),
            activity: parse_int(activity, 0),
            current_command: current_command
          }
        ]

      _ ->
        []
    end
  end

  @doc """
  List panes for one tmux session, returning structured geometry and process
  metadata for topology consumers.
  """
  @spec list_session_panes(String.t()) :: [map()]
  def list_session_panes(session) when is_binary(session) do
    case run(["list-panes", "-s", "-t", session, "-F", @topology_pane_fmt]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_topology_pane_line/1)

      _ ->
        []
    end
  end

  defp parse_topology_pane_line(line) do
    case String.split(line, "|", parts: 16) do
      [
        window_id,
        pane_id,
        index,
        active,
        left,
        top,
        width,
        height,
        current_command,
        pane_activity,
        pane_bell,
        window_activity,
        window_activity_flag,
        window_bell_flag,
        pane_unseen_changes,
        current_path
      ] ->
        pane =
          topology_pane_map(
            window_id,
            pane_id,
            index,
            active,
            left,
            top,
            width,
            height,
            current_command,
            pane_activity,
            pane_bell,
            window_activity,
            window_activity_flag,
            window_bell_flag,
            pane_unseen_changes,
            current_path
          )

        [pane]

      [
        window_id,
        pane_id,
        index,
        active,
        left,
        top,
        width,
        height,
        current_command,
        current_path
      ] ->
        [
          topology_pane_map(
            window_id,
            pane_id,
            index,
            active,
            left,
            top,
            width,
            height,
            current_command,
            "",
            "",
            "0",
            "0",
            "0",
            "0",
            current_path
          )
        ]

      _ ->
        []
    end
  end

  defp topology_pane_map(
         window_id,
         pane_id,
         index,
         active,
         left,
         top,
         width,
         height,
         current_command,
         pane_activity,
         pane_bell,
         window_activity,
         window_activity_flag,
         window_bell_flag,
         pane_unseen_changes,
         current_path
       ) do
    %{
      id: pane_id,
      window_id: window_id,
      index: parse_int(index, 0),
      active: active == "1",
      left: parse_int(left, 0),
      top: parse_int(top, 0),
      width: parse_int(width, 0),
      height: parse_int(height, 0),
      current_command: current_command,
      current_path: current_path,
      activity: pane_activity_timestamp(pane_activity, window_activity),
      activity_flag: truthy?(window_activity_flag) or truthy?(pane_activity),
      bell: truthy?(pane_bell) or truthy?(window_bell_flag),
      unseen_changes: truthy?(pane_unseen_changes)
    }
  end

  defp pane_activity_timestamp(pane_activity, window_activity) do
    case parse_int(pane_activity, 0) do
      value when value > 1 -> value
      _ -> parse_int(window_activity, 0)
    end
  end

  defp truthy?(value) when value in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_), do: false

  @doc "Create a new tmux window in `session` and return its window id."
  @spec new_window(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def new_window(session, opts \\ []) when is_binary(session) do
    args =
      ["new-window", "-P", "-F", "\#{window_id}", "-t", session] ++
        new_window_options(opts)

    case run(args) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, out}}
    end
  end

  defp new_window_options(opts) do
    []
    |> maybe_add_window_name(Keyword.get(opts, :name))
    |> maybe_add_window_cwd(Keyword.get(opts, :cwd))
  end

  defp maybe_add_window_name(args, name) when is_binary(name) and name != "",
    do: args ++ ["-n", name]

  defp maybe_add_window_name(args, _), do: args

  defp maybe_add_window_cwd(args, cwd) when is_binary(cwd) and cwd != "",
    do: args ++ ["-c", cwd]

  defp maybe_add_window_cwd(args, _), do: args

  @doc "Select a tmux window by id or index."
  @spec select_window(String.t(), String.t()) :: :ok | {:error, term()}
  def select_window(session, window_id) when is_binary(session) and is_binary(window_id) do
    case run(["select-window", "-t", "#{session}:#{window_id}"]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc "Select a tmux pane by pane id."
  @spec select_pane(String.t(), String.t()) :: :ok | {:error, term()}
  def select_pane(_session, pane_id) when is_binary(pane_id) do
    case run(["select-pane", "-t", pane_id]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc "Kill a tmux pane by pane id."
  @spec kill_pane(String.t(), String.t()) :: :ok | {:error, term()}
  def kill_pane(session, pane_id) when is_binary(session) and is_binary(pane_id) do
    if String.starts_with?(session, @session_prefix <> "_") do
      case run(["kill-pane", "-t", "#{session}:#{pane_id}"]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {code, out}}
      end
    else
      {:error, :refused_non_devide_session}
    end
  end

  @doc "Split a tmux pane horizontally or vertically."
  @spec split_pane(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def split_pane(session, pane_id, direction, opts \\ [])

  def split_pane(session, pane_id, direction, opts)
      when is_binary(session) and is_binary(pane_id) and direction in ["h", "v"] do
    if String.starts_with?(session, @session_prefix <> "_") do
      case run(
             [
               "split-window",
               "-P",
               "-F",
               "\#{pane_id}",
               "-#{direction}",
               "-t",
               "#{session}:#{pane_id}"
             ] ++ split_pane_options(opts)
           ) do
        {out, 0} -> {:ok, String.trim(out)}
        {out, code} -> {:error, {code, out}}
      end
    else
      {:error, :refused_non_devide_session}
    end
  end

  def split_pane(_session, _pane_id, _direction, _opts), do: {:error, :invalid_direction}

  defp split_pane_options(opts) do
    []
    |> maybe_add_pane_cwd(Keyword.get(opts, :cwd))
  end

  defp maybe_add_pane_cwd(args, cwd) when is_binary(cwd) and cwd != "",
    do: args ++ ["-c", cwd]

  defp maybe_add_pane_cwd(args, _), do: args

  @doc "Resize a tmux pane by direction and cell amount."
  @spec resize_pane(String.t(), String.t(), String.t(), pos_integer() | nil) ::
          :ok | {:error, term()}
  def resize_pane(session, pane_id, direction, amount \\ @resize_amount_default)

  def resize_pane(session, pane_id, direction, amount)
      when is_binary(session) and is_binary(pane_id) and
             direction in ["left", "right", "up", "down"] do
    with {:ok, amount} <- normalize_resize_amount(amount) do
      if String.starts_with?(session, @session_prefix <> "_") do
        case run([
               "resize-pane",
               "-t",
               "#{session}:#{pane_id}",
               resize_flag(direction),
               to_string(amount)
             ]) do
          {_, 0} -> :ok
          {out, code} -> {:error, {code, out}}
        end
      else
        {:error, :refused_non_devide_session}
      end
    end
  end

  def resize_pane(_session, _pane_id, _direction, _amount), do: {:error, :invalid_resize}

  defp normalize_resize_amount(nil), do: {:ok, @resize_amount_default}

  defp normalize_resize_amount(amount)
       when is_integer(amount) and amount > 0 and amount <= @resize_amount_max,
       do: {:ok, amount}

  defp normalize_resize_amount(_amount), do: {:error, :invalid_amount}

  defp resize_flag("left"), do: "-L"
  defp resize_flag("right"), do: "-R"
  defp resize_flag("up"), do: "-U"
  defp resize_flag("down"), do: "-D"

  @doc false
  def resize_amount_default, do: @resize_amount_default

  @doc false
  def resize_amount_max, do: @resize_amount_max

  @doc "Rename a tmux window."
  @spec rename_window(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def rename_window(session, window_id, name)
      when is_binary(session) and is_binary(window_id) and is_binary(name) do
    case run(["rename-window", "-t", "#{session}:#{window_id}", name]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  # Pipe-delimited (devide_* names are sanitized to [A-Za-z0-9_-], so `|` never
  # collides) window listing across every session on the server. Each field maps
  # to TmuxWindowJanitor's kill policy. `automatic_rename` is the load-bearing
  # one: tmux flips it off the instant a user renames a window, so it cleanly
  # separates "auto-named, never touched" windows from ones the operator named.
  @list_windows_fmt ~S(#{session_name}|#{window_id}|#{window_active}|#{window_panes}|#{automatic_rename}|#{window_activity}|#{pane_current_command})

  @doc """
  List every window on the tmux server as maps with the fields the window
  janitor needs. Returns `[]` when no server is running (or tmux errors).
  """
  @spec list_windows() :: [map()]
  def list_windows do
    case run(["list-windows", "-a", "-F", @list_windows_fmt]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_window_line/1)

      _ ->
        []
    end
  end

  defp parse_window_line(line) do
    case String.split(line, "|") do
      [session, window_id, active, panes, auto_rename, activity, current_command] ->
        [
          %{
            session: session,
            window_id: window_id,
            active: active == "1",
            panes: parse_int(panes, 1),
            automatic_rename: auto_rename == "1",
            activity: parse_int(activity, 0),
            current_command: current_command
          }
        ]

      _ ->
        []
    end
  end

  defp parse_int(s, default) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  @list_sessions_fmt ~S(#{session_name}|#{session_attached}|#{session_activity})

  @doc """
  List every session with the fields the session janitor needs. Returns `[]`
  when no server is running (or tmux errors).
  """
  @spec list_sessions() :: [map()]
  def list_sessions do
    case run(["list-sessions", "-F", @list_sessions_fmt]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_session_line/1)

      _ ->
        []
    end
  end

  defp parse_session_line(line) do
    case String.split(line, "|") do
      [session, attached, activity] ->
        [%{session: session, attached: attached != "0", activity: parse_int(activity, 0)}]

      _ ->
        []
    end
  end

  @doc """
  List every pane across all sessions as `{session_name, pane_current_command}`
  tuples. The session janitor uses this to tell "all panes are idle shells"
  (safe to reap) from "something is running in here" (leave alone).
  """
  @spec list_panes() :: [{String.t(), String.t()}]
  def list_panes do
    case run(["list-panes", "-a", "-F", ~S(#{session_name}|#{pane_current_command})]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "|", parts: 2) do
            [session, cmd] -> [{session, cmd}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  Kill a single window, addressed as `"session:window_id"`. Refuses anything
  whose session is not a `devide_*` session — the janitor must never reach
  outside our namespace, mirroring `kill/1`'s safety.
  """
  @spec kill_window(String.t(), String.t()) :: :ok | {:error, term()}
  def kill_window(session, window_id) when is_binary(session) and is_binary(window_id) do
    if String.starts_with?(session, @session_prefix <> "_") do
      case run(["kill-window", "-t", "#{session}:#{window_id}"]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {code, out}}
      end
    else
      {:error, :refused_non_devide_session}
    end
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

  def session_alive?(session), do: session_exists?(session)

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
    * `extended-keys on` (server) — forward modified keys (Ctrl/Shift/Alt combos, etc.) using xterm/kitty extended sequences so apps inside tmux (vim, zsh, etc.) receive them
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
      {["set-option", "-s", "extended-keys", "on"], "extended-keys"},
      {["set-option", "-t", session, "-g", "status", "off"], "status"},
      {["set-option", "-t", session, "-g", "pane-border-status", "off"], "pane-border-status"},
      {["set-option", "-ga", "terminal-overrides", ",xterm-256color:Tc"], "terminal-overrides"},
      {["set-option", "-t", session, "-g", "renumber-windows", "on"], "renumber-windows"},
      # window-size + aggressive-resize make tmux follow the *current* client's
      # TTY size as it changes. Without these, tmux keeps the pane size from
      # session creation — subsequent browser resizes fire SIGWINCH through to
      # tmux but tmux ignores them, so the rendered cell grid stays the wrong
      # shape and the operator sees content cut off / overflowing.
      #
      # NOTE: no `-g` here. `window-size` is a session option; `-g` would set
      # the GLOBAL default for *new* sessions only, leaving this already-
      # created session at its prior value (usually `manual` after an explicit
      # `resize-window` call). Same logic for aggressive-resize (window opt).
      {["set-option", "-t", session, "window-size", "latest"], "window-size"},
      {["set-window-option", "-t", session, "aggressive-resize", "on"], "aggressive-resize"}
    ]

    failures =
      for {args, name} <- options,
          {out, code} = run(args),
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
  def send_command(session, cmd, opts \\ []) when is_binary(session) and is_binary(cmd) do
    target = Keyword.get(opts, :target, session)
    tmux_args = ["send-keys", "-t", target, cmd, "Enter"]
    [bin | args] = send_command_argv(tmux_args, opts)

    case System.cmd(System.find_executable(bin) || bin, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      other -> other
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  defp send_command_argv(tmux_args, opts) do
    case {host_shell?(), Keyword.get(opts, :cwd)} do
      {true, _cwd} ->
        ["tmux" | tmux_args]

      {false, cwd} when is_binary(cwd) and cwd != "" ->
        WorkspaceSource.prepare_local_argv(["tmux" | tmux_args], cwd: cwd)

      {_host_shell?, _cwd} ->
        ["tmux" | tmux_args]
    end
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
    case run(["resize-window", "-t", session, "-x", to_string(cols), "-y", to_string(rows)]) do
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
  # System.cmd. When host-shell mode is enabled, sessions live in host tmux
  # even if the workspace source normally wraps commands through Docker, so
  # one-shot topology/mutation calls must also target host tmux.
  defp run(tmux_args) do
    [cmd | args] = tmux_argv(tmux_args)
    System.cmd(cmd, args, stderr_to_stdout: true)
  end

  defp tmux_argv(tmux_args) do
    if host_shell?() do
      ["tmux" | tmux_args]
    else
      WorkspaceSource.prepare_local_argv(["tmux" | tmux_args])
    end
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
