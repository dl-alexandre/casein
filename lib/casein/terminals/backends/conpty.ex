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
