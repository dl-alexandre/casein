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

  @impl true
  def session_alive?(session) when is_binary(session) do
    case get(session) do
      %{alive?: true} -> true
      _ -> false
    end
  end

  @impl true
  def kill(session) when is_binary(session) do
    ensure_table!()
    :ets.delete(@table, session)
    :ok
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

      pane = new_pane(pane_id, window_id, 0, role, state)

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
         {:ok, source} <- fetch_pane(state, pane_id) do
      pane_seq = state.pane_seq + 1
      new_id = "%#{pane_seq}"
      role = normalize_role(Keyword.get(opts, :role) || source.role)
      index = next_pane_index(state, source.window_id)
      pane = new_pane(new_id, source.window_id, index, role, state)

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
         {:ok, pane} <- fetch_pane(state, pane_id) do
      delta = if is_integer(amount) and amount > 0, do: amount, else: 1

      {width, height} =
        case direction do
          d when d in ["L", "left", "-L"] -> {max(pane.width - delta, 1), pane.height}
          d when d in ["R", "right", "-R"] -> {pane.width + delta, pane.height}
          d when d in ["U", "up", "-U"] -> {pane.width, max(pane.height - delta, 1)}
          d when d in ["D", "down", "-D"] -> {pane.width, pane.height + delta}
          _ -> {pane.width, pane.height}
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

  defp new_pane(id, window_id, index, role, state) do
    %{
      id: id,
      window_id: window_id,
      index: index,
      active: true,
      width: state.cols,
      height: state.rows,
      current_command: "shell",
      current_path: state.cwd,
      role: role,
      title: role || "shell"
    }
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
end
