defmodule TmuxCtl.Client do
  @moduledoc """
  tmux subprocess client: topology reads, pane/window mutations, and capture.

  Subcommand argv is executed through `TmuxCtl.Runner` (configured via
  `config :tmux_ctl, :runner, ...`).
  """

  @behaviour TmuxCtl.Adapter

  @resize_amount_default 5
  @resize_amount_max 50
  @pane_role_option "@devide_pane_role"

  defp session_prefix do
    Application.get_env(:tmux_ctl, :session_prefix, "devide")
  end

  defp managed_session?(session) when is_binary(session) do
    String.starts_with?(session, session_prefix() <> "_")
  end

  def ensure_session(session, cwd) do
    case run(["has-session", "-t", session]) do
      {_, 0} ->
        _ = apply_defaults(session)
        :ok

      _ ->
        case run(
               ["new-session", "-d"] ++
                 terminal_env_flags() ++ ["-s", session, "-c", cwd] ++ default_command_args()
             ) do
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
    [cmd | args] = TmuxCtl.Runner.argv(["attach-session", "-t", session])

    port =
      Port.open({:spawn_executable, System.find_executable(cmd) || cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    {:ok, port}
  end

  @doc """
  Send raw key(s) to a target pane. Defaults to the session's active pane;
  pass `target:` (a pane id like `%3`, window id, or `session:win.pane`) to
  address a specific pane — e.g. so an agent can drive a non-focused pane.
  """
  def send_keys(session, keys, opts \\ []) do
    target = Keyword.get(opts, :target, session)
    run(["send-keys", "-t", target, keys])
  end

  @doc """
  Inject text into a tmux target using a named buffer and paste-buffer.

  This is safer than `send-keys` for multiline prompts and special characters.
  `target` may be a pane id such as `%12`, a session name, or a tmux target like
  `session:window.pane`.
  """
  @spec inject(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def inject(target, text, opts \\ []) when is_binary(target) and is_binary(text) do
    enter? = Keyword.get(opts, :enter, true)
    buffer = "devide_#{System.unique_integer([:positive])}"

    result =
      with :ok <- run_ok(["set-buffer", "-b", buffer, "--", text], opts),
           :ok <- run_ok(["paste-buffer", "-b", buffer, "-t", target], opts) do
        maybe_send_enter(target, enter?, opts)
      end

    _ = run_ok(["delete-buffer", "-b", buffer], opts)

    case result do
      :ok ->
        :telemetry.execute([:dev_ide, :tmux, :inject], %{count: 1}, %{target: target})
        :ok

      {:error, reason} = error ->
        require Logger

        Logger.warning("tmux inject failed",
          target: target,
          reason: inspect(reason)
        )

        :telemetry.execute([:dev_ide, :tmux, :inject, :error], %{count: 1}, %{
          target: target,
          reason: reason
        })

        error
    end
  end

  @doc """
  Capture recent output from a tmux target.

  Returns the captured text instead of soft-failing to an empty binary so callers
  that need a robust interaction boundary can distinguish tmux failures.
  """
  @spec capture_recent(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def capture_recent(target, lines \\ 200, opts \\ [])

  def capture_recent(target, lines, opts)
      when is_binary(target) and is_integer(lines) and lines > 0 do
    ansi_flag = if Keyword.get(opts, :ansi, false), do: ["-e"], else: []
    join_flag = if Keyword.get(opts, :join, true), do: ["-J"], else: []

    run_capture(
      ["capture-pane", "-p"] ++ ansi_flag ++ join_flag ++ ["-t", target, "-S", "-#{lines}"],
      opts
    )
  end

  def capture_recent(_target, _lines, _opts), do: {:error, :invalid_lines}

  defp maybe_send_enter(_target, false, _opts), do: :ok

  defp maybe_send_enter(target, true, opts),
    do: run_ok(["send-keys", "-t", target, "Enter"], opts)

  # `automatic-rename` (hyphenated, the window-option lookup) is 0 once a
  # window has been deliberately named — by the user, `new-window -n`, or a
  # DevIDE rename — and 1 while tmux still auto-names it after the running
  # command. The underscored spelling is NOT a tmux format variable and
  # silently expands to "".
  @topology_window_fmt ~S(#{window_id}|#{window_index}|#{automatic-rename}|#{window_name}|#{window_active}|#{window_panes}|#{window_activity}|#{pane_current_command})
  @topology_pane_fmt ~S(#{window_id}|#{pane_id}|#{pane_index}|#{pane_active}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_current_command}|#{pane_activity}|#{pane_bell}|#{window_activity}|#{window_activity_flag}|#{window_bell_flag}|#{pane_unseen_changes}|#{pane_current_path}|#{pane_zoomed_flag}|#{@devide_pane_role}|#{pane_title})

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
    case String.split(line, "|", parts: 8) do
      [id, index, auto_rename, name, active, panes, activity, current_command] ->
        [
          %{
            id: id,
            index: parse_int(index, 0),
            name: name,
            manual_name: auto_rename == "0",
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

  @doc """
  Windows and panes for one session in a single tmux invocation.

  Chains `list-windows` and `list-panes -s` with tagged format strings so a
  topology read costs one subprocess instead of two. Returns
  `{windows, panes}`; both empty when the session (or the tmux server) is
  gone, which callers can use as a liveness signal without a separate
  `has-session` probe.
  """
  @spec session_topology(String.t()) :: {[map()], [map()]}
  def session_topology(session) when is_binary(session) do
    args = [
      "list-windows",
      "-t",
      session,
      "-F",
      "W|" <> @topology_window_fmt,
      ";",
      "list-panes",
      "-s",
      "-t",
      session,
      "-F",
      "P|" <> @topology_pane_fmt
    ]

    case run(args) do
      {out, 0} ->
        lines = String.split(out, "\n", trim: true)

        windows =
          for "W|" <> rest <- lines, window <- parse_topology_window_line(rest), do: window

        panes = for "P|" <> rest <- lines, pane <- parse_topology_pane_line(rest), do: pane

        {windows, panes}

      _ ->
        {[], []}
    end
  end

  # Window name comes last so a `|` in a user-chosen name can't shift fields
  # (session names are sanitized to [A-Za-z0-9_-], so the leading fields are
  # safe); same for pane paths.
  @directory_window_fmt ~S(#{session_name}|#{window_id}|#{window_index}|#{window_active}|#{window_activity}|#{pane_current_command}|#{automatic-rename}|#{window_name})
  @directory_pane_fmt ~S(#{session_name}|#{window_id}|#{pane_id}|#{pane_active}|#{pane_current_command}|#{pane_activity}|#{window_activity}|#{pane_current_path}|#{@devide_pane_role}|#{pane_title})

  @doc """
  Windows and pane paths for every session on the server, in one tmux
  invocation — the batch read behind `SessionDirectory` enrichment, replacing
  a `list-windows` + `list-panes` subprocess pair per session.

  Returns `{:ok, %{windows: by_session, panes: by_session}}`, or `:error`
  when tmux is unreachable (callers fall back to per-session reads).
  """
  @spec directory_inventory() ::
          {:ok, %{windows: %{String.t() => [map()]}, panes: %{String.t() => [map()]}}} | :error
  def directory_inventory do
    args = [
      "list-windows",
      "-a",
      "-F",
      "W|" <> @directory_window_fmt,
      ";",
      "list-panes",
      "-a",
      "-F",
      "P|" <> @directory_pane_fmt
    ]

    case run(args) do
      {out, 0} ->
        lines = String.split(out, "\n", trim: true)

        windows =
          for("W|" <> rest <- lines, window <- parse_directory_window_line(rest), do: window)
          |> Enum.group_by(& &1.session)

        panes =
          for("P|" <> rest <- lines, pane <- parse_directory_pane_line(rest), do: pane)
          |> Enum.group_by(& &1.session)

        {:ok, %{windows: windows, panes: panes}}

      _ ->
        :error
    end
  end

  defp parse_directory_window_line(line) do
    case String.split(line, "|", parts: 8) do
      [session, id, index, active, activity, current_command, auto_rename, name] ->
        [
          %{
            session: session,
            id: id,
            index: parse_int(index, 0),
            name: name,
            manual_name: auto_rename == "0",
            active: active == "1",
            activity: parse_int(activity, 0),
            current_command: current_command
          }
        ]

      _ ->
        []
    end
  end

  defp parse_directory_pane_line(line) do
    case String.split(line, "|", parts: 10) do
      [
        session,
        window_id,
        pane_id,
        active,
        current_command,
        pane_activity,
        window_activity,
        current_path,
        role,
        pane_title
      ] ->
        [
          %{
            session: session,
            window_id: window_id,
            id: pane_id,
            active: active == "1",
            current_command: current_command,
            activity: pane_activity_timestamp(pane_activity, window_activity),
            current_path: current_path,
            role: blank_to_nil(role),
            pane_title: blank_to_nil(pane_title)
          }
        ]

      [session, window_id, pane_id, active, current_path, role] ->
        [
          %{
            session: session,
            window_id: window_id,
            id: pane_id,
            active: active == "1",
            current_path: current_path,
            role: blank_to_nil(role)
          }
        ]

      [session, window_id, pane_id, active, current_path] ->
        [
          %{
            session: session,
            window_id: window_id,
            id: pane_id,
            active: active == "1",
            current_path: current_path,
            role: nil
          }
        ]

      _ ->
        []
    end
  end

  defp parse_topology_pane_line(line) do
    case String.split(line, "|", parts: 19) do
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
        current_path,
        pane_zoomed,
        role,
        pane_title
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
            pane_activity,
            pane_bell,
            window_activity,
            window_activity_flag,
            window_bell_flag,
            pane_unseen_changes,
            current_path,
            pane_zoomed,
            role,
            pane_title
          )
        ]

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
        current_path,
        pane_zoomed,
        role
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
            pane_activity,
            pane_bell,
            window_activity,
            window_activity_flag,
            window_bell_flag,
            pane_unseen_changes,
            current_path,
            pane_zoomed,
            role,
            nil
          )
        ]

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
        current_path,
        pane_zoomed
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
            pane_activity,
            pane_bell,
            window_activity,
            window_activity_flag,
            window_bell_flag,
            pane_unseen_changes,
            current_path,
            pane_zoomed,
            nil,
            nil
          )
        ]

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
            pane_activity,
            pane_bell,
            window_activity,
            window_activity_flag,
            window_bell_flag,
            pane_unseen_changes,
            current_path,
            "0",
            nil,
            nil
          )
        ]

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
            current_path,
            "0",
            nil,
            nil
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
         current_path,
         pane_zoomed,
         role,
         pane_title
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
      role: blank_to_nil(role),
      pane_title: blank_to_nil(pane_title),
      activity: pane_activity_timestamp(pane_activity, window_activity),
      activity_flag: truthy?(window_activity_flag) or truthy?(pane_activity),
      bell: truthy?(pane_bell) or truthy?(window_bell_flag),
      unseen_changes: truthy?(pane_unseen_changes),
      zoomed?: truthy?(pane_zoomed)
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

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp blank_to_nil(_value), do: nil

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
    terminal_env_flags()
    |> maybe_add_window_name(Keyword.get(opts, :name))
    |> maybe_add_window_cwd(Keyword.get(opts, :cwd))
    |> maybe_add_window_command(Keyword.get(opts, :command))
  end

  defp maybe_add_window_name(args, name) when is_binary(name) and name != "",
    do: args ++ ["-n", name]

  defp maybe_add_window_name(args, _), do: args

  defp maybe_add_window_cwd(args, cwd) when is_binary(cwd) and cwd != "",
    do: args ++ ["-c", cwd]

  defp maybe_add_window_cwd(args, _), do: args

  defp maybe_add_window_command(args, command) when is_binary(command) and command != "",
    do: args ++ [command]

  defp maybe_add_window_command(args, _), do: args ++ default_command_args()

  @doc "Select a tmux window by id or index."
  @spec select_window(String.t(), String.t()) :: :ok | {:error, term()}
  def select_window(session, window_id) when is_binary(session) and is_binary(window_id) do
    case run(["select-window", "-t", "#{session}:#{window_id}"]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc "Cycle to the next or previous tmux window in a session."
  @spec cycle_window(String.t(), String.t()) :: :ok | {:error, term()}
  def cycle_window(session, dir) when dir in ["next", "prev"] do
    flag = if dir == "next", do: "-n", else: "-p"

    case run(["select-window", flag, "-t", session]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc """
  Move every window from the source sessions into the target session.

  Windows are appended to the target session and source sessions naturally
  disappear when their final window is moved. The mutation is intentionally
  scoped to managed DevIDE sessions, matching the destructive pane/window
  guards elsewhere in this adapter.
  """
  @spec consolidate_sessions(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def consolidate_sessions(target_session, source_sessions)
      when is_binary(target_session) and is_list(source_sessions) do
    sources = normalize_source_sessions(source_sessions, target_session)

    cond do
      not managed_session?(target_session) ->
        {:error, :refused_non_devide_session}

      Enum.any?(sources, &(not managed_session?(&1))) ->
        {:error, :refused_non_devide_session}

      sources == [] ->
        {:ok, %{moved_windows: 0, source_sessions: 0}}

      true ->
        Enum.reduce_while(sources, {:ok, %{moved_windows: 0, source_sessions: 0}}, fn source,
                                                                                      {:ok, acc} ->
          case move_session_windows(source, target_session) do
            {:ok, 0} ->
              {:cont, {:ok, acc}}

            {:ok, moved} ->
              {:cont,
               {:ok,
                %{
                  acc
                  | moved_windows: acc.moved_windows + moved,
                    source_sessions: acc.source_sessions + 1
                }}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
    end
  end

  def consolidate_sessions(_target_session, _source_sessions), do: {:error, :invalid_sessions}

  defp normalize_source_sessions(source_sessions, target_session) do
    source_sessions
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 == target_session))
    |> Enum.uniq()
  end

  defp move_session_windows(source_session, target_session) do
    source_session
    |> list_session_windows()
    |> Enum.reduce_while({:ok, 0}, fn window, {:ok, count} ->
      case window_id(window) do
        nil ->
          {:cont, {:ok, count}}

        id ->
          case run([
                 "move-window",
                 "-d",
                 "-s",
                 "#{source_session}:#{id}",
                 "-t",
                 "#{target_session}:"
               ]) do
            {_, 0} -> {:cont, {:ok, count + 1}}
            {out, code} -> {:halt, {:error, {code, out}}}
          end
      end
    end)
  end

  defp window_id(window) when is_map(window) do
    Map.get(window, :id) || Map.get(window, "id") || Map.get(window, :window_id) ||
      Map.get(window, "window_id")
  end

  defp window_id(_window), do: nil

  @doc "Select a tmux pane by pane id."
  @spec select_pane(String.t(), String.t()) :: :ok | {:error, term()}
  def select_pane(_session, pane_id) when is_binary(pane_id) do
    case run(["select-pane", "-t", pane_id]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc "Navigate to an adjacent pane by direction (L/R/U/D), cycle to next (n), or last pane (l)."
  @spec navigate_pane(String.t(), String.t()) :: :ok | {:error, term()}
  def navigate_pane(session, dir) when is_binary(session) and dir in ["L", "R", "U", "D", "l"] do
    case run(["select-pane", "-t", session, "-#{dir}"]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  def navigate_pane(session, "n") when is_binary(session) do
    case run(["select-pane", "-t", "#{session}:.+"]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  def navigate_pane(session, "p") when is_binary(session) do
    case run(["select-pane", "-t", "#{session}:.-"]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  def navigate_pane(_session, _dir), do: {:error, :invalid_direction}

  @doc "Toggle zoom on a tmux pane (resize-pane -Z), like C-b z."
  @spec zoom_pane(String.t(), String.t()) :: :ok | {:error, term()}
  def zoom_pane(session, pane_id) when is_binary(session) and is_binary(pane_id) do
    if managed_session?(session) do
      case run(["resize-pane", "-Z", "-t", pane_target(session, pane_id)]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {code, out}}
      end
    else
      {:error, :refused_non_devide_session}
    end
  end

  @doc """
  Idempotently set zoom on a pane — toggles only when tmux state differs.
  """
  @spec ensure_zoomed(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def ensure_zoomed(session, pane_id, desired?) when is_binary(session) and is_binary(pane_id) do
    actual? = pane_zoomed?(session, pane_id)

    cond do
      desired? == actual? ->
        :ok

      true ->
        zoom_pane(session, pane_id)
    end
  end

  @spec pane_zoomed?(String.t(), String.t()) :: boolean()
  def pane_zoomed?(session, pane_id) when is_binary(session) and is_binary(pane_id) do
    session
    |> list_session_panes()
    |> Enum.find_value(false, fn pane ->
      if pane.id == pane_id, do: Map.get(pane, :zoomed?, false)
    end)
  end

  @doc "Kill every pane in the window except the given one (kill-pane -a)."
  @spec kill_other_panes(String.t(), String.t()) :: :ok | {:error, term()}
  def kill_other_panes(session, pane_id) when is_binary(session) and is_binary(pane_id) do
    if managed_session?(session) do
      case run(["kill-pane", "-a", "-t", pane_target(session, pane_id)]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {code, out}}
      end
    else
      {:error, :refused_non_devide_session}
    end
  end

  @doc ~S(Apply a tmux pane layout preset to the active window, e.g. "tiled".)
  @spec select_layout(String.t(), String.t()) :: :ok | {:error, term()}
  def select_layout(session, layout)
      when is_binary(session) and
             layout in ~w(tiled even-horizontal even-vertical main-horizontal main-vertical) do
    case run(["select-layout", "-t", session, layout]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  def select_layout(_session, _layout), do: {:error, :invalid_layout}

  @doc "Cycle the active window to the next tmux layout preset, like C-b space."
  @spec next_layout(String.t()) :: :ok | {:error, term()}
  def next_layout(session) when is_binary(session) do
    case run(["next-layout", "-t", session]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc "Kill a tmux pane by pane id."
  @spec kill_pane(String.t(), String.t()) :: :ok | {:error, term()}
  def kill_pane(session, pane_id) when is_binary(session) and is_binary(pane_id) do
    if managed_session?(session) do
      case run(["kill-pane", "-t", pane_target(session, pane_id)]) do
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
    if managed_session?(session) do
      case run(
             [
               "split-window",
               "-P",
               "-F",
               "\#{pane_id}",
               "-#{direction}",
               "-t",
               pane_target(session, pane_id)
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

  # tmux pane ids (%N) are server-global; session:%N is parsed as a window name.
  defp pane_target(_session, "%" <> _ = pane_id), do: pane_id
  defp pane_target(session, pane_id), do: "#{session}:#{pane_id}"

  defp split_pane_options(opts) do
    terminal_env_flags()
    |> maybe_add_pane_cwd(Keyword.get(opts, :cwd))
    |> maybe_add_split_command(Keyword.get(opts, :command))
  end

  defp maybe_add_pane_cwd(args, cwd) when is_binary(cwd) and cwd != "",
    do: args ++ ["-c", cwd]

  defp maybe_add_pane_cwd(args, _), do: args

  defp maybe_add_split_command(args, command) when is_binary(command) and command != "",
    do: args ++ [command]

  defp maybe_add_split_command(args, _), do: args ++ default_command_args()

  @doc "Resize a tmux pane by direction and cell amount."
  @spec resize_pane(String.t(), String.t(), String.t(), pos_integer() | nil) ::
          :ok | {:error, term()}
  def resize_pane(session, pane_id, direction, amount \\ @resize_amount_default)

  def resize_pane(session, pane_id, direction, amount)
      when is_binary(session) and is_binary(pane_id) and
             direction in ["left", "right", "up", "down"] do
    with {:ok, amount} <- normalize_resize_amount(amount) do
      if managed_session?(session) do
        case run([
               "resize-pane",
               "-t",
               pane_target(session, pane_id),
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

  @doc """
  Set (or clear) a session's display alias.

  Stored as the per-session tmux user option `@devide_session_alias` so the name
  lives with the tmux session itself — it survives app restarts and leaves the
  load-bearing `devide_<workspace>_<sid>` session name (and MCP scoping) untouched.
  A blank name unsets the option. The scan in `list_sessions/0` reads it back via
  the `@devide_session_alias` tmux format field.
  """
  @spec set_session_alias(String.t(), String.t()) :: :ok | {:error, term()}
  def set_session_alias(session, name) when is_binary(session) do
    args =
      case String.trim(to_string(name || "")) do
        "" -> ["set-option", "-t", session, "-u", "@devide_session_alias"]
        trimmed -> ["set-option", "-t", session, "@devide_session_alias", trimmed]
      end

    case run(args) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc """
  Set or clear a pane's DevIDE role metadata.

  The role is stored as the per-pane tmux user option `@devide_pane_role`, so
  it survives app restarts and is visible through topology reads.
  """
  @spec set_pane_role(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def set_pane_role(session, pane_id, role) when is_binary(session) and is_binary(pane_id) do
    if managed_session?(session) do
      case role_string(role) do
        "" ->
          run_ok(
            ["set-option", "-p", "-t", pane_target(session, pane_id), "-u", @pane_role_option],
            []
          )

        role ->
          if valid_role?(role) do
            run_ok(
              ["set-option", "-p", "-t", pane_target(session, pane_id), @pane_role_option, role],
              []
            )
          else
            {:error, :invalid_role}
          end
      end
    else
      {:error, :refused_non_devide_session}
    end
  end

  defp role_string(role) when is_binary(role), do: String.trim(role)
  defp role_string(_role), do: ""

  defp valid_role?(role), do: String.match?(role, ~r/^[a-z][a-z0-9_-]{0,31}$/)

  # Pipe-delimited (devide_* names are sanitized to [A-Za-z0-9_-], so `|` never
  # collides) window listing across every session on the server. Each field maps
  # to TmuxWindowJanitor's kill policy. `automatic-rename` is the load-bearing
  # one: tmux flips it off the instant a user renames a window, so it cleanly
  # separates "auto-named, never touched" windows from ones the operator named.
  # It must be spelled with the hyphen (the window-option lookup); the
  # underscored form is not a tmux format variable and expands to "".
  @list_windows_fmt ~S(#{session_name}|#{window_id}|#{window_active}|#{window_panes}|#{automatic-rename}|#{window_activity}|#{pane_current_command})

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

  @list_sessions_fmt ~S(#{session_name}|#{session_attached}|#{session_activity}|#{@devide_session_alias})

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
      [session, attached, activity, session_alias] ->
        [
          %{
            session: session,
            attached: attached != "0",
            activity: parse_int(activity, 0),
            session_alias: blank_to_nil(session_alias)
          }
        ]

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
    if managed_session?(session) do
      case run(["kill-window", "-t", "#{session}:#{window_id}"]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {code, out}}
      end
    else
      {:error, :refused_non_devide_session}
    end
  end

  def kill(session) when is_binary(session) do
    if managed_session?(session) do
      kill(session, 10)
    else
      {:error, :refused_non_devide_session}
    end
  end

  def kill(_session), do: {:error, :invalid_session}

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
    options =
      [
        {["set-option", "-t", session, "-g", "mouse", "on"], "mouse"},
        {["set-option", "-s", "escape-time", "0"], "escape-time"},
        {["set-option", "-t", session, "-g", "history-limit", "50000"], "history-limit"},
        {["set-option", "-t", session, "-g", "focus-events", "on"], "focus-events"},
        {["set-option", "-t", session, "-g", "allow-passthrough", "on"], "allow-passthrough"},
        {["set-option", "-s", "set-clipboard", "on"], "set-clipboard"},
        {["set-option", "-s", "extended-keys", "on"], "extended-keys"},
        {["set-option", "-t", session, "-g", "status", "off"], "status"},
        {["set-option", "-t", session, "-g", "pane-border-status", "off"], "pane-border-status"},
        {["set-option", "-t", session, "-g", "pane-border-lines", "single"], "pane-border-lines"},
        {["set-option", "-ga", "terminal-overrides", ",xterm-256color:Tc"], "terminal-overrides"},
        {["set-option", "-t", session, "-g", "renumber-windows", "on"], "renumber-windows"},
        default_command_options(session),
        # `window-size manual` makes DevIDE's SessionOwner the sole writer via
        # explicit `resize-window` calls. `latest` invites any attached tmux
        # client (SSH attach, agent pairing, etc.) to re-pin the window and
        # race DevIDE's focused-viewer policy — the narrow-column-with-dots
        # failure mode. External clients may see letterboxing; DevIDE viewers
        # never will.
        #
        # NOTE: no `-g` here. `window-size` is a session option; `-g` would set
        # the GLOBAL default for *new* sessions only, leaving this already-
        # created session at its prior value.
        {["set-option", "-t", session, "window-size", "manual"], "window-size"},
        terminal_environment_options(session),
        # Host UI pickers replace tmux's choose-tree entirely (the status line
        # is already off). Stray prefixes still reach the PTY — agents sending
        # keys, direct SSH attaches — and would draw tmux's full-screen picker
        # inside the embedded terminal. Rebind to a configurable hint instead.
        # Key tables are server-wide.
        {prefix_window_picker_bind(session), "prefix-w-hint"},
        {prefix_session_picker_bind(session), "prefix-s-hint"}
      ]
      |> List.flatten()

    # Happy path: one tmux invocation with all options chained via `;`
    # (1 subprocess instead of 14). tmux keeps executing the queue after a
    # failed command, so on a non-zero exit we re-run per-option to find
    # out which ones actually failed.
    batched =
      options
      |> Enum.map(fn {args, _name} -> args end)
      |> Enum.intersperse([";"])
      |> List.flatten()

    case run(batched) do
      {_, 0} -> :ok
      _ -> apply_defaults_individually(session, options)
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  defp apply_defaults_individually(session, options) do
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
  end

  @doc """
  Set one tmux session environment variable.

  Variables are inherited by new shells in the session. Use
  `set_environments/2` to push a full agent env map at once.
  """
  def set_environment(session, key, value)
      when is_binary(session) and is_binary(key) and is_binary(value) do
    case run(["set-environment", "-t", session, key, value]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {code, out}}
    end
  end

  @doc "Set many tmux session environment variables (best-effort, continues on partial failure)."
  def set_environments(session, env) when is_binary(session) and is_map(env) do
    failures =
      for {key, value} <- env,
          is_binary(key),
          is_binary(value),
          result = set_environment(session, key, value),
          result != :ok do
        {key, result}
      end

    case failures do
      [] -> :ok
      _ -> {:error, failures}
    end
  end

  defp terminal_environment_options(session) do
    terminal_env()
    |> Enum.map(fn {key, value} ->
      {["set-environment", "-t", session, key, value], "env-#{key}"}
    end)
  end

  defp default_command_options(session) do
    case default_command() do
      nil -> []
      command -> [{["set-option", "-t", session, "default-command", command], "default-command"}]
    end
  end

  defp default_command_args do
    case default_command() do
      nil -> []
      command -> [command]
    end
  end

  defp default_command do
    case Application.get_env(:tmux_ctl, :default_command) do
      command when is_binary(command) ->
        command = String.trim(command)
        if command == "", do: nil, else: command

      _ ->
        nil
    end
  end

  defp terminal_env_flags do
    terminal_env()
    |> Enum.flat_map(fn {key, value} -> ["-e", "#{key}=#{value}"] end)
  end

  defp terminal_env do
    case Application.get_env(:tmux_ctl, :terminal_env, %{}) do
      env when is_map(env) or is_list(env) ->
        env
        |> Enum.filter(fn {key, value} -> is_binary(key) and is_binary(value) end)
        |> Enum.sort_by(fn {key, _value} -> key end)

      _ ->
        []
    end
  end

  defp prefix_window_picker_bind(_session) do
    [
      "bind-key",
      "-T",
      "prefix",
      "w",
      "display-message",
      Application.get_env(
        :tmux_ctl,
        :prefix_window_picker_hint,
        "Use the host UI window picker instead of tmux choose-tree (prefix w)"
      )
    ]
  end

  defp prefix_session_picker_bind(_session) do
    [
      "bind-key",
      "-T",
      "prefix",
      "s",
      "display-message",
      Application.get_env(
        :tmux_ctl,
        :prefix_session_picker_hint,
        "Use the host UI session picker instead of tmux choose-tree (prefix s)"
      )
    ]
  end

  @doc """
  Send `cmd` followed by Enter to the named tmux session.

  Operator clicks an interactive-agent button (claude / grok / opencode
  etc.) → we launch the agent in the existing tmux session that the raw
  pane is attached to. tmux send-keys writes to the pane's stdin
  regardless of whether anything is attached, so this works even before
  the pane is attached.

  Uses the configured tmux runner, which may route to host tmux or a workspace
  wrapper depending on runtime configuration.

  Returns `:ok` on success; System.cmd result tuple otherwise. Fails
  silently with non-zero exit if the session doesn't exist yet — caller
  should put_flash a friendly error in that case.
  """
  def send_command(session, cmd, opts \\ []) when is_binary(session) and is_binary(cmd) do
    target = Keyword.get(opts, :target, session)
    tmux_args = ["send-keys", "-t", target, cmd, "Enter"]

    case run(tmux_args, opts) do
      {_, 0} -> :ok
      other -> other
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  @doc """
  Paste literal text into a pane through a tmux paste buffer.

  This avoids `send-keys` parsing pasted content as tmux key names, which is
  important for multiline snippets, JSON, prompts, and code blocks. Pass
  `target:` to address a pane id; pass `submit: true` to press Enter after the
  paste.
  """
  def paste_text(session, text, opts \\ []) when is_binary(session) and is_binary(text) do
    target = Keyword.get(opts, :target, session)
    buffer = "devide-paste-#{System.unique_integer([:positive])}"

    with {_, 0} <- run_with_input(["load-buffer", "-b", buffer, "-"], text, opts),
         {_, 0} <- run(["paste-buffer", "-d", "-b", buffer, "-t", target]) do
      if Keyword.get(opts, :submit, false) do
        case send_keys(session, "Enter", target: target) do
          :ok -> :ok
          {_, 0} -> :ok
          {:error, reason} -> {:error, reason}
          {out, _code} -> {:error, String.trim(out)}
        end
      else
        :ok
      end
    else
      {out, _code} -> {:error, String.trim(out)}
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  @doc """
  Force tmux to resize the named session's windows to `cols × rows`.

  PTY-driven resize (Ghostty.PTY.resize → ioctl TIOCSWINSZ → SIGWINCH on the
  attached tmux client) should be enough, but with `tmux new-session -A`
  re-attaching to a session that survives BEAM/page-reload cycles, tmux's
  Under `window-size manual`, DevIDE's SessionOwner is the sole writer; an
  explicit `resize-window` is how the authoritative viewer size reaches tmux.

  Resizes EVERY window in the session, not just the current one: under
  `window-size manual` each window keeps its own size, and the viewer shows
  whichever window its tab strip selects — a window resized only while
  current stays at its old size (or the 80x24 default it was created with)
  when the operator switches to it, parking the terminal content in a corner
  of the viewport until the next drift check. Also records the size as the
  session's `default-size` so windows created later (agent worktree panes)
  spawn at the viewer size instead of tmux's 80x24 default.

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
    x = to_string(cols)
    y = to_string(rows)

    case run(["list-windows", "-t", session, "-F", "\#{window_id}"]) do
      {out, 0} ->
        _ = run(["set-option", "-t", session, "default-size", "#{x}x#{y}"])

        out
        |> String.split("\n", trim: true)
        |> Enum.each(fn window_id ->
          run(["resize-window", "-t", "#{session}:#{window_id}", "-x", x, "-y", y])
        end)

        :ok

      _ ->
        # Window enumeration failed (session gone, tmux unreachable): fall
        # back to the current-window best effort.
        case run(["resize-window", "-t", session, "-x", x, "-y", y]) do
          {_, 0} -> :ok
          other -> other
        end
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  @doc """
  Force a full redraw of every client attached to `session`.

  DevIDE renders tmux through server-side emulator grids that consume the
  attached PTY client's byte stream, and tmux only sends diffs against its own
  model of that client's screen. Once an emulator grid diverges from that
  model (replay on reconnect, resize races, dropped bytes), the corruption is
  permanent — tmux has no reason to repaint cells it believes are already
  correct. `refresh-client` discards that assumption and redraws the entire
  screen, converging every consumer back to the true pane content. Best-effort
  for the same reasons as `resize_window/3`.
  """
  def refresh_client(session) when is_binary(session) do
    case run(["list-clients", "-t", session, "-F", "\#{client_name}"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.each(fn client -> run(["refresh-client", "-t", client]) end)

        :ok

      other ->
        other
    end
  rescue
    e in [ErlangError] -> {:error, Exception.message(e)}
  end

  @doc """
  Current size of the named session's active window, as `{cols, rows}`.

  Used to bring a *reattached* PTY up at the session's existing width rather
  than the caller's hardcoded default. Under `window-size manual` the window
  keeps its last explicit size, so a resumed session opens at the real width
  instead of collapsing to the attach PTY's default.

  Returns `{:ok, {cols, rows}}`, or `:error` when the session is absent or the
  query/parse fails (caller falls back to its default size).
  """
  @spec window_size(String.t()) :: {:ok, {pos_integer(), pos_integer()}} | :error
  def window_size(session) when is_binary(session) do
    case run(["display-message", "-p", "-t", session, "\#{window_width} \#{window_height}"]) do
      {out, 0} ->
        with [w, h] <- out |> String.trim() |> String.split(~r/\s+/, trim: true),
             {cols, ""} when cols > 0 <- Integer.parse(w),
             {rows, ""} when rows > 0 <- Integer.parse(h) do
          {:ok, {cols, rows}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ in [ErlangError] -> :error
  end

  @doc """
  Capture the full scrollback of a tmux session's first window/pane, with
  escape sequences preserved (`-e`) and wrapped lines joined (`-J`).
  Returns an empty binary on failure or when the session does not exist —
  the caller seeds an output buffer with the result, so soft-fail is the
  right shape.

  Used to recover pane history when a Session GenServer is re-created
  against an existing tmux session (server restart, replay path).

  On tmux >= 3.6, output may contain literal tab characters and U+FFFD bytes
  for invalid UTF-8 sequences.

  Options (all optional; defaults preserve the replay-path behavior):
    * `:target` — pane/window to capture (default: session's active pane).
      A pane id like `%3` lets an agent read a non-focused pane.
    * `:ansi` — keep ANSI escape sequences (default `true`). Pass `false`
      for plain text — cheaper for an agent to read.
    * `:lines` — return only the last N lines (tail). Omit for full history.
  """
  def capture_scrollback(session, opts \\ []) do
    target = Keyword.get(opts, :target, session)
    ansi_flag = if Keyword.get(opts, :ansi, true), do: ["-e"], else: []
    args = ["capture-pane", "-p"] ++ ansi_flag ++ ["-J", "-S", "-", "-t", target]

    case run(args) do
      {output, 0} -> tail_lines(output, Keyword.get(opts, :lines))
      _ -> <<>>
    end
  end

  # Keep only the last N logical lines. `-J` already joined wrapped lines, so
  # splitting on "\n" is line-accurate. Public for unit testing; not part of
  # the documented API.
  @doc false
  def tail_lines(output, n) when is_integer(n) and n > 0 do
    output
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  def tail_lines(output, _), do: output

  @server_version_key {__MODULE__, :server_version}

  @doc """
  Best-effort tmux server version as `{major, minor}` (e.g. `{3, 4}`), or `nil`
  when it cannot be parsed. Cached in `:persistent_term` — the binary does not
  change under a running server, and the cutover to a new binary restarts the
  BEAM anyway.
  """
  @spec server_version() :: {non_neg_integer(), non_neg_integer()} | nil
  def server_version do
    case :persistent_term.get(@server_version_key, :miss) do
      :miss ->
        version = detect_server_version()
        :persistent_term.put(@server_version_key, version)
        version

      version ->
        version
    end
  end

  defp detect_server_version do
    # `tmux -V` is answered during early argument parsing, before any server
    # connection or config load, so the server label / `-f` flags are harmless.
    case run(["-V"]) do
      {out, 0} -> parse_server_version(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_server_version(out) do
    case Regex.run(~r/(\d+)\.(\d+)/, out) do
      [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)}
      _ -> nil
    end
  end

  @doc false
  @spec reset_version_cache() :: :ok
  def reset_version_cache do
    :persistent_term.erase(@server_version_key)
    :ok
  end

  defp run_ok(tmux_args, opts) do
    case run(tmux_args, opts) do
      {_, 0} -> :ok
      {out, code} -> {:error, tmux_error(tmux_args, code, out, opts)}
    end
  rescue
    e in [ErlangError, File.Error] ->
      {:error, tmux_exception(tmux_args, e, opts)}
  end

  defp run_capture(tmux_args, opts) do
    case run(tmux_args, opts) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, tmux_error(tmux_args, code, out, opts)}
    end
  rescue
    e in [ErlangError, File.Error] ->
      {:error, tmux_exception(tmux_args, e, opts)}
  end

  defp tmux_error(tmux_args, code, out, opts) do
    %{command: safe_command(tmux_args, opts), exit_status: code, output: out}
  end

  defp tmux_exception(tmux_args, error, opts) do
    %{
      command: safe_command(tmux_args, opts),
      exit_status: :exception,
      output: Exception.message(error)
    }
  end

  defp safe_command(tmux_args, opts) do
    tmux_args
    |> redact_sensitive_args()
    |> TmuxCtl.Runner.argv(opts)
  end

  defp redact_sensitive_args(["set-buffer", "-b", buffer, "--", _text]),
    do: ["set-buffer", "-b", buffer, "--", "[REDACTED]"]

  defp redact_sensitive_args(tmux_args), do: tmux_args

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

  defp run(tmux_args, opts \\ []) when is_list(tmux_args), do: TmuxCtl.Runner.run(tmux_args, opts)

  # bin comes from the configured tmux runner, and input_path is generated internally.
  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp run_with_input(tmux_args, input, opts) when is_list(tmux_args) and is_binary(input) do
    [bin | args] = TmuxCtl.Runner.argv(tmux_args, opts)
    executable = System.find_executable(bin) || bin
    input_path = tmux_input_path()

    try do
      case File.write(input_path, input, [:binary, :exclusive]) do
        :ok ->
          System.cmd(
            System.find_executable("sh") || "sh",
            [
              "-c",
              ~S/input_path=$1; shift; cat "$input_path" | "$@"/,
              "devide-run-with-input",
              input_path,
              executable | args
            ],
            stderr_to_stdout: true
          )

        {:error, reason} ->
          {:file.format_error(reason) |> IO.iodata_to_binary(), 1}
      end
    after
      File.rm(input_path)
    end
  end

  defp tmux_input_path do
    suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "devide-tmux-input-#{suffix}")
  end
end
