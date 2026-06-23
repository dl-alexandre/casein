defmodule DevideMob.Terminal do
  @moduledoc """
  Terminal backend abstraction — the VT engine differs by where the BEAM runs:

  * **host (dev)** — `ghostty_ex`'s `Ghostty.Terminal` (a GenServer), whose NIF
    loads from a prebuilt host binary.
  * **on-device (android/ios)** — the project NIF `DevideMob.Nifs.GhosttyVt`
    (a resource), with `libghostty-vt.a` statically linked into the app binary.
    `ghostty_ex`'s NIF can't load here, and ours can't load on the host (its
    `ghostty_terminal_*` symbols are only resolved at the device app link).

  Both return the **identical cell shape** `[[{grapheme, fg, bg, flags}]]`
  (`ghostty_ex`'s `Cell` *is* that 4-tuple), so the renderer is backend-agnostic.

  No PTY here — the shell/PTY runs host-side and streams bytes to `write/2`
  (Model-B-over-the-wire); the device never forks a shell.
  """

  alias DevideMob.Nifs.GhosttyVt

  @type t :: {:nif, reference()} | {:ghostty_ex, pid()}

  @max_scrollback 1000

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(cols, rows) do
    case runtime() do
      :host ->
        {:ok, term} = Ghostty.Terminal.start_link(cols: cols, rows: rows)
        {:ghostty_ex, term}

      _device ->
        {:nif, GhosttyVt.nif_new(cols, rows, @max_scrollback)}
    end
  end

  @spec write(t(), iodata()) :: :ok
  def write({:ghostty_ex, t}, bytes), do: Ghostty.Terminal.write(t, bytes)
  def write({:nif, res}, bytes), do: GhosttyVt.nif_vt_write(res, IO.iodata_to_binary(bytes))

  @spec cells(t()) :: [[{binary(), {0..255, 0..255, 0..255} | nil, term(), integer()}]]
  def cells({:ghostty_ex, t}), do: Ghostty.Terminal.cells(t)
  def cells({:nif, res}), do: GhosttyVt.nif_render_cells(res)

  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor({:ghostty_ex, t}), do: Ghostty.Terminal.cursor(t)
  def cursor({:nif, res}), do: GhosttyVt.nif_get_cursor(res)

  @spec resize(t(), pos_integer(), pos_integer()) :: :ok
  def resize({:ghostty_ex, t}, cols, rows), do: Ghostty.Terminal.resize(t, cols, rows)
  def resize({:nif, res}, cols, rows), do: GhosttyVt.nif_resize(res, cols, rows)

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
