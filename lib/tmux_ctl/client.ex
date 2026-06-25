defmodule TmuxCtl.Client do
  @moduledoc """
  tmux subprocess client: topology reads, pane/window mutations, and capture.

  Subcommand argv is executed through `TmuxCtl.Runner` (configured via
  `config :tmux_ctl, :runner, ...`).
  """

  @behaviour TmuxCtl.Adapter

  @resize_amount_default 5
  @resize_amount_max 50

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

  @topology_window_fmt ~S(#{window_id}|#{window_index}|#{window_name}|#{window_active}|#{window_panes}|#{window_activity}|#{pane_current_command})
  @topology_pane_fmt ~S(#{window_id}|#{pane_id}|#{pane_index}|#{pane_active}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_current_command}|#{pane_activity}|#{pane_bell}|#{window_activity}|#{window_activity_flag}|#{window_bell_flag}|#{pane_unseen_changes}|#{pane_current_path}|#{pane_zoomed_flag})

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
  @directory_window_fmt ~S(#{session_name}|#{window_id}|#{window_index}|#{window_active}|#{window_activity}|#{pane_current_command}|#{window_name})
  @directory_pane_fmt ~S(#{session_name}|#{window_id}|#{pane_id}|#{pane_active}|#{pane_current_path})

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
    case String.split(line, "|", parts: 7) do
      [session, id, index, active, activity, current_command, name] ->
        [
          %{
            session: session,
            id: id,
            index: parse_int(index, 0),
            name: name,
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
    case String.split(line, "|", parts: 5) do
      [session, window_id, pane_id, active, current_path] ->
        [
          %{
            session: session,
            window_id: window_id,
            id: pane_id,
            active: active == "1",
            current_path: current_path
          }
        ]

      _ ->
        []
    end
  end

  defp parse_topology_pane_line(line) do
    case String.split(line, "|", parts: 17) do
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
            pane_zoomed
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
            "0"
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
            "0"
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
         pane_zoomed
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

  @doc "Cycle to the next or previous tmux window in a session."
  @spec cycle_window(String.t(), String.t()) :: :ok | {:error, term()}
  def cycle_window(session, dir) when dir in ["next", "prev"] do
    flag = if dir == "next", do: "-n", else: "-p"

    case run(["select-window", flag, "-t", session]) do
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
    []
    |> maybe_add_pane_cwd(Keyword.get(opts, :cwd))
    |> maybe_add_split_command(Keyword.get(opts, :command))
  end

  defp maybe_add_pane_cwd(args, cwd) when is_binary(cwd) and cwd != "",
    do: args ++ ["-c", cwd]

  defp maybe_add_pane_cwd(args, _), do: args

  defp maybe_add_split_command(args, command) when is_binary(command) and command != "",
    do: args ++ [command]

  defp maybe_add_split_command(args, _), do: args

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

  defp blank_to_nil(value) do
    case String.trim(to_string(value || "")) do
      "" -> nil
      trimmed -> trimmed
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
      {["set-option", "-t", session, "-g", "pane-border-lines", "0"], "pane-border-lines"},
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
      {["set-window-option", "-t", session, "aggressive-resize", "on"], "aggressive-resize"},
      # Host UI pickers replace tmux's choose-tree entirely (the status line
      # is already off). Stray prefixes still reach the PTY — agents sending
      # keys, direct SSH attaches — and would draw tmux's full-screen picker
      # inside the embedded terminal. Rebind to a configurable hint instead.
      # Key tables are server-wide.
      {prefix_window_picker_bind(session), "prefix-w-hint"},
      {prefix_session_picker_bind(session), "prefix-s-hint"}
    ]

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

  Host-direct invocation (same rationale as resize_window/3).

  Returns `:ok` on success; System.cmd result tuple otherwise. Fails
  silently with non-zero exit if the session doesn't exist yet — caller
  should put_flash a friendly error in that case.
  """
  # sobelow_skip ["CI.System"]
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

  defp send_command_argv(tmux_args, opts), do: TmuxCtl.Runner.argv(tmux_args, opts)

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
