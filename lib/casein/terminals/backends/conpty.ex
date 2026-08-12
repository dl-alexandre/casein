defmodule Casein.Terminals.Backends.ConPTY do
  @moduledoc """
  ConPTY-shaped peer for `Casein.Terminals.Backend`.

  **Scaffold, not a full Windows host replacement.** Product multipane/session
  ownership on Windows desktop still lives in `Casein.Desktop.PowerShellSession`
  (ConPTY via Ghostty transport + Job Objects). This module:

  1. Implements every `Casein.Terminals.Backend` callback so the behaviour seam
     has a named Windows peer beside `Backends.Tmux`.
  2. Accepts native spawn locations (`:native` / `{:native, cwd}`) that Tmux
     rejects, returning a `SpawnSpec` that describes ConPTY launch intent.
  3. Fails closed on non-Windows hosts with `{:error, :windows_host_required}`
     so Linux CI never pretends to exercise ConPTY.

  Wiring `Casein.Terminals.Session` onto this backend for full cockpit parity
  remains a follow-up; do not configure `:terminal_backend` to this module in
  production until session attach/input/topology are fully delegated.
  """

  @behaviour Casein.Terminals.Backend

  alias Casein.Terminals.Backend.SpawnSpec

  @impl true
  def session_name(workspace_name, sid)
      when is_binary(workspace_name) and is_binary(sid) do
    digest =
      (workspace_name <> "\0" <> sid)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "conpty_" <> digest
  end

  @impl true
  def spawn_spec({:native, cwd}, session) when is_binary(cwd) and is_binary(session) do
    native_spawn_spec(cwd, session)
  end

  def spawn_spec(:native, session) when is_binary(session) do
    native_spawn_spec(File.cwd!(), session)
  end

  def spawn_spec({:local, cwd}, session) when is_binary(cwd) and is_binary(session) do
    # Local desktop on Windows is native ConPTY, not tmux.
    if windows_host?() do
      native_spawn_spec(cwd, session)
    else
      {:error, :windows_host_required}
    end
  end

  def spawn_spec(loc, _session), do: {:error, {:unsupported_location, loc}}

  @impl true
  def ensure_session(session, cwd), do: require_windows(session, cwd, :ensure_session)

  @impl true
  def attach(session), do: require_windows(session, :attach)

  @impl true
  def session_exists?(_session), do: false

  @impl true
  def session_alive?(_session), do: false

  @impl true
  def kill(session), do: require_windows(session, :kill)

  @impl true
  def send_keys(session, keys, opts \\ [])

  def send_keys(session, keys, opts) when is_binary(keys) and is_list(opts) do
    require_windows(session, {:send_keys, keys, opts})
  end

  @impl true
  def capture_recent(session, lines, opts \\ [])

  def capture_recent(session, lines, opts)
      when is_integer(lines) and lines > 0 and is_list(opts) do
    require_windows(session, {:capture_recent, lines, opts})
  end

  @impl true
  def capture_scrollback(session, opts \\ [])

  def capture_scrollback(session, opts) when is_list(opts) do
    # Tmux returns a bare string; keep the callback type while failing closed.
    _ = require_windows(session, {:capture_scrollback, opts})
    ""
  end

  @impl true
  def resize_window(session, cols, rows)
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
    require_windows(session, {:resize_window, cols, rows})
  end

  @impl true
  def window_size(session), do: require_windows(session, :window_size)

  @impl true
  def list_session_windows(_session), do: []

  @impl true
  def list_session_panes(_session), do: []

  @impl true
  def session_topology(_session), do: {[], []}

  @impl true
  def new_window(session, opts \\ [])

  def new_window(session, opts) when is_list(opts) do
    require_windows(session, {:new_window, opts})
  end

  @impl true
  def select_window(session, window_id) when is_binary(window_id) do
    require_windows(session, {:select_window, window_id})
  end

  @impl true
  def kill_window(session, window_id) when is_binary(window_id) do
    require_windows(session, {:kill_window, window_id})
  end

  @impl true
  def split_pane(session, pane_id, direction, opts \\ [])

  def split_pane(session, pane_id, direction, opts)
      when is_binary(pane_id) and is_binary(direction) and is_list(opts) do
    require_windows(session, {:split_pane, pane_id, direction, opts})
  end

  @impl true
  def select_pane(session, pane_id) when is_binary(pane_id) do
    require_windows(session, {:select_pane, pane_id})
  end

  @impl true
  def kill_pane(session, pane_id) when is_binary(pane_id) do
    require_windows(session, {:kill_pane, pane_id})
  end

  @impl true
  def resize_pane(session, pane_id, direction, amount)
      when is_binary(pane_id) and is_binary(direction) do
    require_windows(session, {:resize_pane, pane_id, direction, amount})
  end

  @impl true
  def set_pane_role(session, pane_id, role) when is_binary(pane_id) do
    require_windows(session, {:set_pane_role, pane_id, role})
  end

  # --- Full TmuxCtl.Adapter surface (Backend #896) ---------------------------
  # Scaffold stubs: fail closed on non-Windows; refuse as unwired on Windows.

  @impl true
  def send_command(session, cmd, opts \\ [])

  def send_command(session, cmd, opts) when is_binary(cmd) and is_list(opts) do
    require_windows(session, {:send_command, cmd, opts})
  end

  @impl true
  def paste_text(session, text, opts \\ [])

  def paste_text(session, text, opts) when is_binary(text) and is_list(opts) do
    require_windows(session, {:paste_text, text, opts})
  end

  @impl true
  def inject(session, text, opts \\ [])

  def inject(session, text, opts) when is_binary(text) and is_list(opts) do
    require_windows(session, {:inject, text, opts})
  end

  @impl true
  def apply_defaults(session), do: require_windows(session, :apply_defaults)

  @impl true
  def list_sessions, do: []

  @impl true
  def list_windows, do: []

  @impl true
  def list_panes, do: []

  @impl true
  def directory_inventory, do: {:ok, %{windows: %{}, panes: %{}}}

  @impl true
  def last_window(session), do: require_windows(session, :last_window)

  @impl true
  def cycle_window(session, dir) when is_binary(dir) do
    require_windows(session, {:cycle_window, dir})
  end

  @impl true
  def consolidate_sessions(session, sources) when is_list(sources) do
    require_windows(session, {:consolidate_sessions, sources})
  end

  @impl true
  def rename_window(session, window_id, name)
      when is_binary(window_id) and is_binary(name) do
    require_windows(session, {:rename_window, window_id, name})
  end

  @impl true
  def set_session_alias(session, name) when is_binary(name) do
    require_windows(session, {:set_session_alias, name})
  end

  @impl true
  def refresh_client(session), do: require_windows(session, :refresh_client)

  @impl true
  def navigate_pane(session, dir) when is_binary(dir) do
    require_windows(session, {:navigate_pane, dir})
  end

  @impl true
  def zoom_pane(session, pane_id) when is_binary(pane_id) do
    require_windows(session, {:zoom_pane, pane_id})
  end

  @impl true
  def swap_pane(session, pane_id, direction)
      when is_binary(pane_id) and is_binary(direction) do
    require_windows(session, {:swap_pane, pane_id, direction})
  end

  @impl true
  def ensure_zoomed(session, pane_id, desired?)
      when is_binary(pane_id) and is_boolean(desired?) do
    require_windows(session, {:ensure_zoomed, pane_id, desired?})
  end

  @impl true
  def kill_other_panes(session, pane_id) when is_binary(pane_id) do
    require_windows(session, {:kill_other_panes, pane_id})
  end

  @impl true
  def select_layout(session, layout) when is_binary(layout) do
    require_windows(session, {:select_layout, layout})
  end

  @impl true
  def next_layout(session), do: require_windows(session, :next_layout)

  @impl true
  def resize_amount_default, do: 5

  @impl true
  def resize_amount_max, do: 50

  @impl true
  def set_environment(session, key, value)
      when is_binary(key) and is_binary(value) do
    require_windows(session, {:set_environment, key, value})
  end

  @impl true
  def set_environments(session, env) when is_map(env) do
    require_windows(session, {:set_environments, env})
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
  def server_version, do: nil

  @doc false
  @spec windows_host?(:os.type()) :: boolean()
  def windows_host?(type \\ :os.type())
  def windows_host?({:win32, _}), do: true
  def windows_host?(_), do: false

  @doc false
  @spec native_spawn_spec(Path.t(), String.t()) :: {:ok, SpawnSpec.t()} | {:error, term()}
  def native_spawn_spec(cwd, session) when is_binary(cwd) and is_binary(session) do
    # Describes intent only. The Ghostty/ConPTY bridge owns real process creation
    # and Job Object assignment on Windows hosts (`casein_ghostty_windows`).
    {:ok,
     %SpawnSpec{
       command: [
         ~c"casein-conpty",
         ~c"--session",
         String.to_charlist(session),
         ~c"--shell",
         ~c"powershell.exe"
       ],
       exec_opts: [
         {:cd, to_charlist(cwd)},
         {:transport, :conpty},
         {:job_object, :kill_on_close},
         {:create_suspended, true}
       ]
     }}
  end

  defp require_windows(_session, _op) do
    if windows_host?() do
      {:error, :conpty_backend_not_wired}
    else
      {:error, :windows_host_required}
    end
  end

  defp require_windows(_session, _cwd, _op) do
    if windows_host?() do
      {:error, :conpty_backend_not_wired}
    else
      {:error, :windows_host_required}
    end
  end
end
