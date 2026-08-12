defmodule Casein.Terminals.Backends.Fake do
  @moduledoc """
  In-memory `Casein.Terminals.Backend` for contract tests and Linux-safe fakes.

  This is **not** Windows coverage. It proves product code can drive sessions,
  windows, panes, input, capture, resize, and topology through the Backend
  behaviour without tmux or ConPTY. Real native Windows execution stays on
  `Casein.Desktop.PowerShellSession` / ConPTY bridge hosts.
  """

  @behaviour Casein.Terminals.Backend

  alias Casein.Terminals.Backend.SpawnSpec

  @table __MODULE__.Table
  @default_cols 120
  @default_rows 40
  @pane_roles ~w(operator agent verify preview)

  @type session_state :: %{
          cwd: String.t(),
          alive?: boolean(),
          cols: pos_integer(),
          rows: pos_integer(),
          windows: [map()],
          panes: [map()],
          scrollback: %{optional(String.t()) => String.t()},
          window_seq: non_neg_integer(),
          pane_seq: non_neg_integer()
        }

  @doc "Reset all fake sessions. Call from test setup."
  @spec reset!() :: :ok
  def reset! do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Snapshot one session for assertions."
  @spec get(String.t()) :: session_state() | nil
  def get(session) when is_binary(session) do
    ensure_table!()

    case :ets.lookup(@table, session) do
      [{^session, state}] -> state
      [] -> nil
    end
  end

  @impl true
  def session_name(workspace_name, sid)
      when is_binary(workspace_name) and is_binary(sid) do
    "fake_" <> sanitize(workspace_name) <> "_" <> sanitize(sid)
  end

  @impl true
  def spawn_spec({:local, cwd}, session) when is_binary(cwd) and is_binary(session) do
    {:ok,
     %SpawnSpec{
       command: ~c"fake-backend-local",
       exec_opts: [cd: to_charlist(cwd), session: session]
     }}
  end

  def spawn_spec({:remote, host, path}, session)
      when is_binary(host) and is_binary(path) and is_binary(session) do
    {:ok,
     %SpawnSpec{
       command: ~c"fake-backend-remote",
       exec_opts: [host: host, path: path, session: session]
     }}
  end

  def spawn_spec({:native, cwd}, session) when is_binary(cwd) and is_binary(session) do
    {:ok,
     %SpawnSpec{
       command: ~c"fake-backend-native",
       exec_opts: [cd: to_charlist(cwd), session: session, transport: :conpty]
     }}
  end

  def spawn_spec(:native, session) when is_binary(session) do
    spawn_spec({:native, File.cwd!()}, session)
  end

  def spawn_spec(loc, _session), do: {:error, {:unsupported_location, loc}}

  @impl true
  def ensure_session(session, cwd) when is_binary(session) do
    ensure_table!()
    cwd = normalize_cwd(cwd)

    case get(session) do
      nil ->
        put_session(session, new_session(cwd))
        :ok

      state ->
        put_session(session, %{state | cwd: cwd, alive?: true})
        :ok
    end
  end

  @impl true
  def attach(session) when is_binary(session) do
    with {:ok, _state} <- fetch_alive(session) do
      # No real Port; callers that need a port must not use Fake for PTY attach.
      {:ok, :fake_port}
    end
  end

  @impl true
  def session_exists?(session) when is_binary(session) do
    ensure_table!()
    match?([{^session, _}], :ets.lookup(@table, session))
  end

  @doc """
  Adapter-compatible existence check with optional `cwd:` (container/local recovery).

  Not a Backend callback — mirrors `Backends.Tmux.session_exists?/2` so product
  recovery paths that pass `cwd:` can exercise Fake without a real adapter.
  """
  def session_exists?(session, opts) when is_binary(session) and is_list(opts) do
    # cwd is accepted for API parity; Fake does not gate existence on path.
    _ = Keyword.get(opts, :cwd)
    session_exists?(session)
  end

  @impl true
  def session_alive?(session) when is_binary(session) do
    case get(session) do
      %{alive?: true} -> true
      _ -> false
    end
  end

  @doc "Mark a session present but not alive (recovery / attach failure paths)."
  @spec mark_dead!(String.t()) :: :ok | {:error, :session_not_found}
  def mark_dead!(session) when is_binary(session) do
    case get(session) do
      nil ->
        {:error, :session_not_found}

      state ->
        put_session(session, %{state | alive?: false})
        :ok
    end
  end

  @impl true
  def list_sessions do
    ensure_table!()

    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
    |> Enum.map(fn session ->
      %{session: session, attached: false, activity: nil}
    end)
  end

  @doc "Session ids only (test helper; `list_sessions/0` returns adapter maps)."
  @spec session_ids() :: [String.t()]
  def session_ids do
    ensure_table!()
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @impl true
  def kill(session) when is_binary(session) do
    ensure_table!()
    :ets.delete(@table, session)
    :ok
  end

  @impl true
  def apply_defaults(session) when is_binary(session) do
    with {:ok, _state} <- fetch_alive(session), do: :ok
  end

  @impl true
  def send_keys(session, keys, opts \\ [])

  def send_keys(session, keys, opts)
      when is_binary(session) and is_binary(keys) and is_list(opts) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, pane_id} <- resolve_pane_target(state, opts) do
      entry = Map.get(state.scrollback, pane_id, "")
      updated = %{state | scrollback: Map.put(state.scrollback, pane_id, entry <> keys)}
      put_session(session, updated)
      :ok
    end
  end

  @impl true
  def send_command(session, command, opts \\ [])

  def send_command(session, command, opts)
      when is_binary(session) and is_binary(command) and is_list(opts) do
    payload =
      if String.ends_with?(command, "\n") do
        command
      else
        command <> "\n"
      end

    send_keys(session, payload, opts)
  end

  @impl true
  def paste_text(session, text, opts \\ [])

  def paste_text(session, text, opts)
      when is_binary(session) and is_binary(text) and is_list(opts) do
    with :ok <- send_keys(session, text, opts) do
      if Keyword.get(opts, :submit, false) do
        send_keys(session, "\n", opts)
      else
        :ok
      end
    end
  end

  @impl true
  def inject(session, text, opts \\ [])

  def inject(session, text, opts)
      when is_binary(session) and is_binary(text) and is_list(opts) do
    enter? = Keyword.get(opts, :enter, true)

    with :ok <- paste_text(session, text, Keyword.put(opts, :submit, false)) do
      if enter?, do: send_keys(session, "\n", opts), else: :ok
    end
  end

  @impl true
  def capture_recent(session, lines, opts \\ [])

  def capture_recent(session, lines, opts)
      when is_binary(session) and is_integer(lines) and lines > 0 and is_list(opts) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, pane_id} <- resolve_pane_target(state, opts) do
      text = Map.get(state.scrollback, pane_id, "")

      clipped =
        text
        |> String.split("\n")
        |> Enum.take(-lines)
        |> Enum.join("\n")

      {:ok, clipped}
    end
  end

  @impl true
  def capture_scrollback(session, opts \\ [])

  def capture_scrollback(session, opts) when is_binary(session) and is_list(opts) do
    case capture_recent(session, 10_000, opts) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  @impl true
  def resize_window(session, cols, rows)
      when is_binary(session) and is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
    with {:ok, state} <- fetch_alive(session) do
      panes =
        Enum.map(state.panes, fn pane ->
          if pane.active, do: Map.merge(pane, %{width: cols, height: rows}), else: pane
        end)

      put_session(session, %{state | cols: cols, rows: rows, panes: panes})
      :ok
    end
  end

  @impl true
  def window_size(session) when is_binary(session) do
    with {:ok, state} <- fetch_alive(session) do
      {:ok, {state.cols, state.rows}}
    end
  end

  @impl true
  def list_session_windows(session) when is_binary(session) do
    case get(session) do
      nil -> []
      state -> Enum.sort_by(state.windows, & &1.index)
    end
  end

  @impl true
  def list_session_panes(session) when is_binary(session) do
    case get(session) do
      nil -> []
      state -> Enum.sort_by(state.panes, &{window_index(state, &1.window_id), &1.index})
    end
  end

  @impl true
  def session_topology(session) when is_binary(session) do
    {list_session_windows(session), list_session_panes(session)}
  end

  @impl true
  def new_window(session, opts \\ [])

  def new_window(session, opts) when is_binary(session) and is_list(opts) do
    with {:ok, state} <- fetch_alive(session) do
      window_seq = state.window_seq + 1
      pane_seq = state.pane_seq + 1
      window_id = "@#{window_seq}"
      pane_id = "%#{pane_seq}"
      name = Keyword.get(opts, :name) || Keyword.get(opts, :window_name) || "window-#{window_seq}"
      role = normalize_role(Keyword.get(opts, :role))

      window = %{
        id: window_id,
        index: window_seq - 1,
        name: name,
        active: true,
        panes: 1,
        automatic_rename: false
      }

      pane = new_pane(pane_id, window_id, 0, role, state, state.cwd, nil)

      windows =
        state.windows
        |> Enum.map(&Map.put(&1, :active, false))
        |> Kernel.++([window])

      panes =
        state.panes
        |> Enum.map(&Map.put(&1, :active, false))
        |> Kernel.++([pane])

      put_session(session, %{
        state
        | windows: windows,
          panes: panes,
          window_seq: window_seq,
          pane_seq: pane_seq
      })

      {:ok, window_id}
    end
  end

  @impl true
  def select_window(session, window_id)
      when is_binary(session) and is_binary(window_id) do
    with {:ok, state} <- fetch_alive(session),
         true <- Enum.any?(state.windows, &(&1.id == window_id)) || {:error, :invalid_window} do
      windows =
        Enum.map(state.windows, fn window ->
          Map.put(window, :active, window.id == window_id)
        end)

      first_pane =
        state.panes
        |> Enum.filter(&(&1.window_id == window_id))
        |> Enum.min_by(& &1.index, fn -> nil end)

      panes =
        Enum.map(state.panes, fn pane ->
          Map.put(pane, :active, first_pane != nil and pane.id == first_pane.id)
        end)

      put_session(session, %{state | windows: windows, panes: panes})
      :ok
    end
  end

  @impl true
  def kill_window(session, window_id)
      when is_binary(session) and is_binary(window_id) do
    with {:ok, state} <- fetch_alive(session),
         true <- Enum.any?(state.windows, &(&1.id == window_id)) || {:error, :invalid_window},
         true <- length(state.windows) > 1 || {:error, :last_window} do
      removed_ids =
        state.panes
        |> Enum.filter(&(&1.window_id == window_id))
        |> Enum.map(& &1.id)

      windows = Enum.reject(state.windows, &(&1.id == window_id))
      panes = Enum.reject(state.panes, &(&1.window_id == window_id))
      scrollback = Map.drop(state.scrollback, removed_ids)

      state = %{state | windows: windows, panes: panes, scrollback: scrollback}
      state = ensure_active_focus(state)
      put_session(session, state)
      :ok
    end
  end

  @impl true
  def split_pane(session, pane_id, direction, opts \\ [])

  def split_pane(session, pane_id, direction, opts)
      when is_binary(session) and is_binary(pane_id) and is_binary(direction) and is_list(opts) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, source} <- fetch_pane(state, pane_id),
         {:ok, split_dir} <- normalize_split_direction(direction) do
      pane_seq = state.pane_seq + 1
      new_id = "%#{pane_seq}"
      role = normalize_role(Keyword.get(opts, :role) || source.role)
      index = next_pane_index(state, source.window_id)
      cwd = Keyword.get(opts, :cwd) || source.current_path || state.cwd
      pane = new_pane(new_id, source.window_id, index, role, state, cwd, split_dir)

      panes =
        state.panes
        |> Enum.map(&Map.put(&1, :active, false))
        |> Kernel.++([Map.put(pane, :active, true)])

      windows =
        Enum.map(state.windows, fn window ->
          if window.id == source.window_id do
            %{window | panes: window.panes + 1, active: true}
          else
            Map.put(window, :active, false)
          end
        end)

      put_session(session, %{
        state
        | panes: panes,
          windows: windows,
          pane_seq: pane_seq
      })

      {:ok, new_id}
    end
  end

  @impl true
  def select_pane(session, pane_id)
      when is_binary(session) and is_binary(pane_id) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, pane} <- fetch_pane(state, pane_id) do
      panes =
        Enum.map(state.panes, fn entry ->
          Map.put(entry, :active, entry.id == pane_id)
        end)

      windows =
        Enum.map(state.windows, fn window ->
          Map.put(window, :active, window.id == pane.window_id)
        end)

      put_session(session, %{state | panes: panes, windows: windows})
      :ok
    end
  end

  @impl true
  def kill_pane(session, pane_id)
      when is_binary(session) and is_binary(pane_id) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, pane} <- fetch_pane(state, pane_id),
         true <- length(state.panes) > 1 || {:error, :last_pane} do
      panes = Enum.reject(state.panes, &(&1.id == pane_id))
      scrollback = Map.delete(state.scrollback, pane_id)

      windows =
        state.windows
        |> Enum.map(fn window ->
          if window.id == pane.window_id do
            %{window | panes: max(window.panes - 1, 0)}
          else
            window
          end
        end)
        |> Enum.reject(fn window ->
          window.id == pane.window_id and window.panes == 0 and length(state.windows) > 1
        end)

      state = %{state | panes: panes, windows: windows, scrollback: scrollback}
      state = ensure_active_focus(state)
      put_session(session, state)
      :ok
    end
  end

  @impl true
  def resize_pane(session, pane_id, direction, amount)
      when is_binary(session) and is_binary(pane_id) and is_binary(direction) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, pane} <- fetch_pane(state, pane_id),
         {:ok, axis} <- normalize_resize_direction(direction) do
      delta = if is_integer(amount) and amount > 0, do: amount, else: 1

      {width, height} =
        case axis do
          :left -> {max(pane.width - delta, 1), pane.height}
          :right -> {pane.width + delta, pane.height}
          :up -> {pane.width, max(pane.height - delta, 1)}
          :down -> {pane.width, pane.height + delta}
        end

      panes =
        Enum.map(state.panes, fn entry ->
          if entry.id == pane_id, do: %{entry | width: width, height: height}, else: entry
        end)

      put_session(session, %{state | panes: panes})
      :ok
    end
  end

  @impl true
  def set_pane_role(session, pane_id, role)
      when is_binary(session) and is_binary(pane_id) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, _pane} <- fetch_pane(state, pane_id),
         {:ok, role} <- validate_role(role) do
      panes =
        Enum.map(state.panes, fn entry ->
          if entry.id == pane_id, do: %{entry | role: role}, else: entry
        end)

      put_session(session, %{state | panes: panes})
      :ok
    end
  end

  @impl true
  def directory_inventory do
    ensure_table!()

    sessions = session_ids()

    windows =
      Map.new(sessions, fn session ->
        {session, list_session_windows(session)}
      end)

    panes =
      Map.new(sessions, fn session ->
        {session, list_session_panes(session)}
      end)

    {:ok, %{windows: windows, panes: panes}}
  end

  @impl true
  def list_windows do
    ensure_table!()

    Enum.flat_map(session_ids(), fn session ->
      list_session_windows(session)
      |> Enum.map(&Map.put(&1, :session, session))
    end)
  end

  @impl true
  def list_panes do
    ensure_table!()

    Enum.flat_map(session_ids(), fn session ->
      list_session_panes(session)
      |> Enum.map(&Map.put(&1, :session, session))
    end)
  end

  @impl true
  def last_window(session) when is_binary(session) do
    with {:ok, state} <- fetch_alive(session),
         %{} = active <- Enum.find(state.windows, & &1.active),
         candidates when candidates != [] <- Enum.reject(state.windows, &(&1.id == active.id)),
         %{} = prev <- Enum.max_by(candidates, & &1.index, fn -> nil end) do
      select_window(session, prev.id)
    else
      nil -> {:error, :no_previous_window}
      [] -> {:error, :no_previous_window}
      other -> other
    end
  end

  @impl true
  def cycle_window(session, dir) when is_binary(session) and dir in ["next", "prev"] do
    with {:ok, state} <- fetch_alive(session),
         [_ | _] = windows <- Enum.sort_by(state.windows, & &1.index) do
      active_idx = Enum.find_index(windows, & &1.active) || 0

      next_idx =
        case dir do
          "next" -> rem(active_idx + 1, length(windows))
          "prev" -> rem(active_idx - 1 + length(windows), length(windows))
        end

      select_window(session, Enum.at(windows, next_idx).id)
    else
      [] -> {:error, :session_not_found}
      other -> other
    end
  end

  def cycle_window(_session, _dir), do: {:error, :invalid_direction}

  @impl true
  def consolidate_sessions(target, sources)
      when is_binary(target) and is_list(sources) do
    with {:ok, target_state} <- fetch_alive(target) do
      Enum.reduce_while(sources, {:ok, target_state, 0}, fn source, {:ok, tstate, moved} ->
        case get(source) do
          nil ->
            {:cont, {:ok, tstate, moved}}

          sstate ->
            {tstate, n} = absorb_session(tstate, sstate)
            :ets.delete(@table, source)
            put_session(target, tstate)
            {:cont, {:ok, tstate, moved + n}}
        end
      end)
      |> case do
        {:ok, _state, moved} -> {:ok, %{moved_windows: moved}}
      end
    end
  end

  @impl true
  def rename_window(session, window_id, name)
      when is_binary(session) and is_binary(window_id) and is_binary(name) do
    with {:ok, state} <- fetch_alive(session),
         true <- Enum.any?(state.windows, &(&1.id == window_id)) || {:error, :invalid_window} do
      windows =
        Enum.map(state.windows, fn window ->
          if window.id == window_id,
            do: %{window | name: name, automatic_rename: false},
            else: window
        end)

      put_session(session, %{state | windows: windows})
      :ok
    end
  end

  @impl true
  def set_session_alias(session, name) when is_binary(session) and is_binary(name) do
    with {:ok, state} <- fetch_alive(session) do
      put_session(session, Map.put(state, :alias, name))
      :ok
    end
  end

  @impl true
  def refresh_client(session) when is_binary(session) do
    with {:ok, _state} <- fetch_alive(session), do: :ok
  end

  @impl true
  def navigate_pane(session, dir) when is_binary(session) and is_binary(dir) do
    with {:ok, state} <- fetch_alive(session),
         panes when panes != [] <-
           Enum.sort_by(state.panes, &{window_index(state, &1.window_id), &1.index}),
         active_idx <- Enum.find_index(panes, & &1.active) || 0 do
      next_idx =
        case dir do
          d when d in ["R", "D", "n", "l"] -> rem(active_idx + 1, length(panes))
          d when d in ["L", "U", "p"] -> rem(active_idx - 1 + length(panes), length(panes))
          _ -> active_idx
        end

      select_pane(session, Enum.at(panes, next_idx).id)
    else
      [] -> {:error, :invalid_pane}
      other -> other
    end
  end

  @impl true
  def zoom_pane(session, pane_id) when is_binary(session) and is_binary(pane_id) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, _pane} <- fetch_pane(state, pane_id) do
      panes =
        Enum.map(state.panes, fn entry ->
          Map.put(entry, :zoomed, entry.id == pane_id and not Map.get(entry, :zoomed, false))
        end)

      put_session(session, %{state | panes: panes})
      :ok
    end
  end

  @impl true
  def swap_pane(session, pane_id, direction)
      when is_binary(session) and is_binary(pane_id) and is_binary(direction) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, pane} <- fetch_pane(state, pane_id),
         siblings <-
           state.panes
           |> Enum.filter(&(&1.window_id == pane.window_id))
           |> Enum.sort_by(& &1.index),
         true <- length(siblings) > 1 || {:error, :no_sibling},
         idx when not is_nil(idx) <- Enum.find_index(siblings, &(&1.id == pane_id)) do
      other_idx =
        case direction do
          d when d in ["U", "L"] -> rem(idx - 1 + length(siblings), length(siblings))
          d when d in ["D", "R"] -> rem(idx + 1, length(siblings))
          _ -> nil
        end

      if is_nil(other_idx) do
        {:error, :invalid_direction}
      else
        a = Enum.at(siblings, idx)
        b = Enum.at(siblings, other_idx)

        panes =
          Enum.map(state.panes, fn entry ->
            cond do
              entry.id == a.id -> %{entry | index: b.index}
              entry.id == b.id -> %{entry | index: a.index}
              true -> entry
            end
          end)

        put_session(session, %{state | panes: panes})
        :ok
      end
    end
  end

  @impl true
  def ensure_zoomed(session, pane_id, desired?)
      when is_binary(session) and is_binary(pane_id) and is_boolean(desired?) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, pane} <- fetch_pane(state, pane_id) do
      if Map.get(pane, :zoomed, false) == desired? do
        :ok
      else
        zoom_pane(session, pane_id)
      end
    end
  end

  @impl true
  def kill_other_panes(session, pane_id)
      when is_binary(session) and is_binary(pane_id) do
    with {:ok, state} <- fetch_alive(session),
         {:ok, keep} <- fetch_pane(state, pane_id) do
      removed =
        state.panes
        |> Enum.reject(&(&1.id == pane_id))
        |> Enum.map(& &1.id)

      panes = Enum.filter(state.panes, &(&1.id == pane_id))
      scrollback = Map.take(state.scrollback, [pane_id])

      windows =
        Enum.map(state.windows, fn window ->
          if window.id == keep.window_id do
            %{window | panes: 1, active: true}
          else
            Map.put(window, :active, false)
          end
        end)
        |> Enum.filter(fn window ->
          window.id == keep.window_id or
            Enum.any?(panes, &(&1.window_id == window.id))
        end)

      panes = Enum.map(panes, &Map.put(&1, :active, true))

      put_session(session, %{
        state
        | panes: panes,
          windows: windows,
          scrollback: scrollback
      })

      _ = removed
      :ok
    end
  end

  @impl true
  def select_layout(session, layout) when is_binary(session) and is_binary(layout) do
    with {:ok, state} <- fetch_alive(session) do
      put_session(session, Map.put(state, :layout, layout))
      :ok
    end
  end

  @impl true
  def next_layout(session) when is_binary(session) do
    layouts = ~w(even-horizontal even-vertical main-horizontal main-vertical tiled)

    with {:ok, state} <- fetch_alive(session) do
      current = Map.get(state, :layout)
      idx = Enum.find_index(layouts, &(&1 == current)) || -1
      next = Enum.at(layouts, rem(idx + 1, length(layouts)))
      put_session(session, Map.put(state, :layout, next))
      :ok
    end
  end

  @impl true
  def resize_amount_default, do: 5

  @impl true
  def resize_amount_max, do: 50

  @impl true
  def set_environment(session, key, value)
      when is_binary(session) and is_binary(key) and is_binary(value) do
    with {:ok, state} <- fetch_alive(session) do
      env = Map.get(state, :env, %{})
      put_session(session, Map.put(state, :env, Map.put(env, key, value)))
      :ok
    end
  end

  @impl true
  def set_environments(session, env) when is_binary(session) and is_map(env) do
    with {:ok, state} <- fetch_alive(session) do
      merged = Map.merge(Map.get(state, :env, %{}), env)
      put_session(session, Map.put(state, :env, merged))
      :ok
    end
  end

  @impl true
  def tail_lines(output, n) when is_binary(output) and is_integer(n) and n > 0 do
    output
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  def tail_lines(output, _) when is_binary(output), do: output
  def tail_lines(_, _), do: ""

  @impl true
  def server_version, do: {0, 0}

  @doc """
  Apply a SessionTemplate dry-run plan (list of step maps) against a Fake session.

  Supports the subset product template executors need on Backend:
  `new_window`, `split_pane`, `send_command`, `select_pane`, and role metadata.
  Returns `{:ok, ref_map}` mapping plan refs to window/pane ids.
  """
  @spec apply_plan(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def apply_plan(session, steps) when is_binary(session) and is_list(steps) do
    with {:ok, _state} <- fetch_alive(session) do
      Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, refs} ->
        case apply_plan_step(session, step, refs) do
          {:ok, refs} -> {:cont, {:ok, refs}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  @doc "Fetch one pane map by id, or nil."
  @spec get_pane(String.t(), String.t()) :: map() | nil
  def get_pane(session, pane_id) when is_binary(session) and is_binary(pane_id) do
    case get(session) do
      nil -> nil
      state -> Enum.find(state.panes, &(&1.id == pane_id))
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @table
    end

    :ok
  end

  defp put_session(session, state) do
    ensure_table!()
    true = :ets.insert(@table, {session, state})
    :ok
  end

  defp new_session(cwd) do
    window = %{
      id: "@1",
      index: 0,
      name: "shell",
      active: true,
      panes: 1,
      automatic_rename: true
    }

    pane = %{
      id: "%1",
      window_id: "@1",
      index: 0,
      active: true,
      width: @default_cols,
      height: @default_rows,
      current_command: "shell",
      current_path: cwd,
      role: "operator",
      title: "shell"
    }

    %{
      cwd: cwd,
      alive?: true,
      cols: @default_cols,
      rows: @default_rows,
      windows: [window],
      panes: [pane],
      scrollback: %{"%1" => ""},
      window_seq: 1,
      pane_seq: 1
    }
  end

  defp new_pane(id, window_id, index, role, state, cwd, split_dir) do
    path = if is_binary(cwd) and cwd != "", do: cwd, else: state.cwd

    %{
      id: id,
      window_id: window_id,
      index: index,
      active: true,
      width: state.cols,
      height: state.rows,
      current_command: "shell",
      current_path: path,
      role: role,
      title: role || "shell",
      split_direction: split_dir
    }
  end

  defp apply_plan_step(session, step, refs) when is_map(step) do
    action = Map.get(step, :action) || Map.get(step, "action")
    ref = Map.get(step, :ref) || Map.get(step, "ref")
    target_ref = Map.get(step, :target_ref) || Map.get(step, "target_ref")
    params = Map.get(step, :params) || Map.get(step, "params") || %{}
    metadata = Map.get(step, :metadata) || Map.get(step, "metadata") || %{}

    role =
      Map.get(step, :role) ||
        Map.get(step, "role") ||
        Map.get(params, :role) ||
        Map.get(params, "role") ||
        Map.get(metadata, :role) ||
        Map.get(metadata, "role")

    case action do
      "new_window" ->
        opts =
          [
            name: param(params, :name),
            role: role
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        with {:ok, window_id} <- new_window(session, opts),
             {:ok, root_pane} <- root_pane_for_window(session, window_id) do
          # Planner refs: window ref → window id; pane:<window>:root → root pane.
          refs =
            refs
            |> maybe_put_ref(ref, window_id)
            |> maybe_put_ref(planner_root_pane_ref(ref), root_pane.id)
            |> maybe_put_ref(root_pane_ref(ref), root_pane.id)

          if is_binary(role) and role != "" do
            _ = set_pane_role(session, root_pane.id, role)
          end

          {:ok, refs}
        end

      "split_pane" ->
        target = resolve_ref(refs, target_ref)
        direction = param(params, :direction) || "h"

        opts =
          [role: role, cwd: param(params, :cwd)]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        with true <- is_binary(target) || {:error, :invalid_pane},
             {:ok, pane_id} <- split_pane(session, target, direction, opts) do
          if is_binary(role) and role != "" do
            _ = set_pane_role(session, pane_id, role)
          end

          {:ok, maybe_put_ref(refs, ref, pane_id)}
        end

      "send_command" ->
        target = resolve_ref(refs, target_ref)
        command = param(params, :command) || ""

        with true <- is_binary(target) || {:error, :invalid_pane},
             :ok <- send_command(session, command, target: target) do
          {:ok, refs}
        end

      "select_pane" ->
        target = resolve_ref(refs, target_ref) || resolve_ref(refs, ref)

        with true <- is_binary(target) || {:error, :invalid_pane},
             :ok <- select_pane(session, target) do
          {:ok, refs}
        end

      # Feature panes (preview/file) are not Fake's job — acknowledge and continue
      # so agent_pair-style terminal plans still apply when mixed templates appear.
      "attach_pane" ->
        {:ok, refs}

      other when is_binary(other) ->
        {:error, {:unsupported_plan_action, other}}

      _ ->
        {:error, :invalid_plan_step}
    end
  end

  defp apply_plan_step(_session, _step, _refs), do: {:error, :invalid_plan_step}

  defp root_pane_for_window(session, window_id) do
    case get(session) do
      nil ->
        {:error, :session_not_found}

      state ->
        pane =
          state.panes
          |> Enum.filter(&(&1.window_id == window_id))
          |> Enum.min_by(& &1.index, fn -> nil end)

        if pane, do: {:ok, pane}, else: {:error, :invalid_pane}
    end
  end

  defp root_pane_ref(nil), do: nil
  defp root_pane_ref(window_ref) when is_binary(window_ref), do: window_ref <> ":root"

  # SessionTemplate.Planner uses "pane:<window_id>:root" for the window root pane.
  defp planner_root_pane_ref(nil), do: nil

  defp planner_root_pane_ref("window:" <> rest) when is_binary(rest),
    do: "pane:" <> rest <> ":root"

  defp planner_root_pane_ref(_), do: nil

  defp resolve_ref(_refs, nil), do: nil
  defp resolve_ref(refs, ref) when is_binary(ref), do: Map.get(refs, ref) || ref

  defp maybe_put_ref(refs, nil, _value), do: refs
  defp maybe_put_ref(refs, ref, value) when is_binary(ref), do: Map.put(refs, ref, value)

  defp param(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp param(_params, _key), do: nil

  defp normalize_split_direction(direction) do
    case direction do
      d when d in ["h", "horizontal", "right", "-h"] -> {:ok, "h"}
      d when d in ["v", "vertical", "down", "-v"] -> {:ok, "v"}
      _ -> {:error, :invalid_direction}
    end
  end

  defp normalize_resize_direction(direction) do
    case direction do
      d when d in ["L", "left", "-L"] -> {:ok, :left}
      d when d in ["R", "right", "-R"] -> {:ok, :right}
      d when d in ["U", "up", "-U"] -> {:ok, :up}
      d when d in ["D", "down", "-D"] -> {:ok, :down}
      _ -> {:error, :invalid_direction}
    end
  end

  defp fetch_alive(session) do
    case get(session) do
      %{alive?: true} = state -> {:ok, state}
      %{alive?: false} -> {:error, :session_not_alive}
      nil -> {:error, :session_not_found}
    end
  end

  defp fetch_pane(state, pane_id) do
    case Enum.find(state.panes, &(&1.id == pane_id)) do
      nil -> {:error, :invalid_pane}
      pane -> {:ok, pane}
    end
  end

  defp resolve_pane_target(state, opts) do
    case Keyword.get(opts, :target) || Keyword.get(opts, :pane) do
      nil ->
        case Enum.find(state.panes, & &1.active) do
          nil -> {:error, :invalid_pane}
          pane -> {:ok, pane.id}
        end

      pane_id when is_binary(pane_id) ->
        with {:ok, pane} <- fetch_pane(state, pane_id), do: {:ok, pane.id}
    end
  end

  defp ensure_active_focus(state) do
    windows =
      case Enum.find(state.windows, & &1.active) || List.first(state.windows) do
        nil ->
          []

        active ->
          Enum.map(state.windows, &Map.put(&1, :active, &1.id == active.id))
      end

    active_window = Enum.find(windows, & &1.active)

    panes =
      case preferred_pane(state.panes, active_window && active_window.id) do
        nil ->
          state.panes

        pane ->
          Enum.map(state.panes, &Map.put(&1, :active, &1.id == pane.id))
      end

    %{state | windows: windows, panes: panes}
  end

  defp preferred_pane(panes, nil), do: List.first(panes)

  defp preferred_pane(panes, window_id) do
    panes
    |> Enum.filter(&(&1.window_id == window_id))
    |> Enum.min_by(& &1.index, fn -> List.first(panes) end)
  end

  defp next_pane_index(state, window_id) do
    state.panes
    |> Enum.filter(&(&1.window_id == window_id))
    |> Enum.map(& &1.index)
    |> Enum.max(fn -> -1 end)
    |> Kernel.+(1)
  end

  defp window_index(state, window_id) do
    case Enum.find(state.windows, &(&1.id == window_id)) do
      nil -> 0
      window -> window.index
    end
  end

  defp normalize_cwd(cwd) when is_binary(cwd) and cwd != "", do: cwd
  defp normalize_cwd(_), do: File.cwd!()

  defp normalize_role(nil), do: nil
  defp normalize_role(role) when role in @pane_roles, do: role
  defp normalize_role(_), do: nil

  defp validate_role(nil), do: {:ok, nil}
  defp validate_role(role) when role in @pane_roles, do: {:ok, role}
  defp validate_role(_), do: {:error, :invalid_pane_role}

  defp sanitize(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
  end

  defp absorb_session(target_state, source_state) do
    window_base = target_state.window_seq
    pane_base = target_state.pane_seq

    {windows, window_map, window_seq} =
      Enum.reduce(source_state.windows, {target_state.windows, %{}, window_base}, fn win,
                                                                                     {acc, map,
                                                                                      seq} ->
        seq = seq + 1
        new_id = "@#{seq}"
        map = Map.put(map, win.id, new_id)
        win = %{win | id: new_id, index: seq - 1, active: false}
        {acc ++ [win], map, seq}
      end)

    {panes, scrollback, pane_seq} =
      Enum.reduce(
        source_state.panes,
        {target_state.panes, target_state.scrollback, pane_base},
        fn pane, {acc, sb, seq} ->
          seq = seq + 1
          new_id = "%#{seq}"
          new_window = Map.fetch!(window_map, pane.window_id)
          text = Map.get(source_state.scrollback, pane.id, "")
          pane = %{pane | id: new_id, window_id: new_window, active: false, index: seq - 1}
          {acc ++ [pane], Map.put(sb, new_id, text), seq}
        end
      )

    state = %{
      target_state
      | windows: windows,
        panes: panes,
        scrollback: scrollback,
        window_seq: window_seq,
        pane_seq: pane_seq
    }

    {state, map_size(window_map)}
  end
end
