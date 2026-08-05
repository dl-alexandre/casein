defmodule CaseinMob.Terminal do
  @moduledoc """
  Terminal backend abstraction — the VT engine differs by where the BEAM runs:

  * **host (dev)** — `ghostty_ex`'s `Ghostty.Terminal` (a GenServer), whose NIF
    loads from a prebuilt host binary.
  * **Android** — the project NIF `CaseinMob.Nifs.GhosttyVt` (a resource),
    with `libghostty-vt.a` statically linked into the Android app binary.
  * **iOS** — the Casein-owned native Canvas bridge. The iOS build deliberately
    does not link `GhosttyVt`, so this route must never probe or call that NIF.

  The host and Android backends return the **identical cell shape**
  `[[{grapheme, fg, bg, flags}]]` (`ghostty_ex`'s `Cell` *is* that 4-tuple).
  iOS forwards one bounded current frame to its native renderer instead.

  No PTY here — the shell/PTY runs host-side and streams bytes to `write/2`
  (Model-B-over-the-wire); the device never forks a shell.
  """

  alias CaseinMob.Nifs.GhosttyVt

  @type backend :: :ghostty_vt | :host_ghostty | :ios_canvas
  @type t :: {:nif, reference()} | {:ghostty_ex, pid()} | :ios_canvas

  @max_scrollback 1000

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(cols, rows) do
    case backend() do
      :host_ghostty ->
        {:ok, term} = Ghostty.Terminal.start_link(cols: cols, rows: rows)
        {:ghostty_ex, term}

      :ghostty_vt ->
        {:nif, GhosttyVt.nif_new(cols, rows, @max_scrollback)}

      :ios_canvas ->
        :ios_canvas
    end
  end

  @doc "Select the loaded renderer for a native platform without probing a NIF."
  @spec backend() :: backend()
  def backend, do: backend(runtime())

  @doc false
  @spec backend(:host | :android | :ios) :: backend()
  def backend(:host), do: :host_ghostty
  def backend(:android), do: :ghostty_vt
  def backend(:ios), do: :ios_canvas

  @spec write(t(), iodata()) :: :ok
  def write({:ghostty_ex, t}, bytes), do: Ghostty.Terminal.write(t, bytes)
  def write({:nif, res}, bytes), do: GhosttyVt.nif_vt_write(res, IO.iodata_to_binary(bytes))

  def write(:ios_canvas, _bytes),
    do: raise(ArgumentError, "iOS terminal bytes must use the native Canvas bridge")

  @spec cells(t()) :: [[{binary(), {0..255, 0..255, 0..255} | nil, term(), integer()}]]
  def cells({:ghostty_ex, t}), do: Ghostty.Terminal.cells(t)
  def cells({:nif, res}), do: GhosttyVt.nif_render_cells(res)

  def cells(:ios_canvas),
    do: raise(ArgumentError, "iOS terminal cells are owned by the native Canvas bridge")

  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor({:ghostty_ex, t}), do: Ghostty.Terminal.cursor(t)
  def cursor({:nif, res}), do: GhosttyVt.nif_get_cursor(res)

  def cursor(:ios_canvas),
    do: raise(ArgumentError, "iOS terminal cursor is owned by the native Canvas bridge")

  @spec resize(t(), pos_integer(), pos_integer()) :: :ok
  def resize({:ghostty_ex, t}, cols, rows), do: Ghostty.Terminal.resize(t, cols, rows)
  def resize({:nif, res}, cols, rows), do: GhosttyVt.nif_resize(res, cols, rows)

  def resize(:ios_canvas, _cols, _rows), do: :ok

  @doc "Discard every rendered cell and scrollback entry."
  @spec reset(t(), pos_integer(), pos_integer()) :: t()
  def reset({:ghostty_ex, pid}, cols, rows) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    new(cols, rows)
  end

  def reset({:nif, resource} = terminal, _cols, _rows) do
    GhosttyVt.nif_reset(resource)
    terminal
  end

  def reset(:ios_canvas, _cols, _rows), do: :ios_canvas

  @doc "Release host-side terminal resources when a screen exits."
  @spec close(t()) :: :ok
  def close({:ghostty_ex, pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  def close({:nif, _resource}), do: :ok
  def close(:ios_canvas), do: :ok

  @doc """
  `:host` (no native Mob runtime — dev/`mix`) | `:android` | `:ios`.
  Mirrors `Mob.App`'s host-safe `:mob_nif.platform()` probe.
  """
  @spec runtime() :: :host | :android | :ios
  def runtime do
    :mob_nif.platform()
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> :host
  end

  @spec host?() :: boolean()
  def host?, do: runtime() == :host
end
