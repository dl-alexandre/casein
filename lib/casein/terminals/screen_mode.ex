defmodule Casein.Terminals.ScreenMode do
  @moduledoc """
  Streaming detector for the alternate-screen switch in a PTY byte stream.

  The browser's layout needs to know whether a pane is running a full-screen TUI
  or a scrolling shell, because the two want opposite things when the soft
  keyboard opens:

    * a scrolling shell can be row-pinned — hold the PTY at its keyboard-closed
      size and scroll the grid, so tmux never reflows;
    * an alternate-screen TUI draws to the whole grid and pins its own UI to the
      bottom row. Cropping it to a keyboard-sized window shows a slice of a
      layout built for a taller screen. It needs a truthful size and a real
      resize, which it handles by redrawing.

  Without this signal the client had to guess, and guessed wrong for every
  full-screen TUI (see `terminal_layout_model.mjs`).

  The emulator tracks this internally but exposes no predicate, and tmux only
  reports it via its `alternate_on` format variable on a topology poll — which
  lags by seconds and would couple the render path to the topology subsystem.
  The bytes are already
  flowing through the pane worker, so scan them here, the same way
  `Casein.Terminals.Osc133` scans the stream for shell-integration markers.

  Recognizes the DEC private mode set/reset sequences that toggle the alternate
  screen: `1049` (current), plus the legacy `47` and `1047`. A bounded carry
  buffer keeps a sequence split across PTY chunks parseable once the rest
  arrives.
  """

  defstruct mode: :normal, pending: ""

  @type mode :: :normal | :alternate
  @type t :: %__MODULE__{mode: mode(), pending: binary()}

  @csi_private "\e[?"
  # Every private-mode sequence we care about is short; anything longer is not
  # one, so the carry can stay tiny. Without a cap a stream that never completes
  # a sequence would grow the buffer without bound.
  @max_pending 64
  @alt_modes ["1049", "47", "1047"]

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec mode(t()) :: mode()
  def mode(%__MODULE__{mode: mode}), do: mode

  @spec alternate?(t()) :: boolean()
  def alternate?(%__MODULE__{mode: mode}), do: mode == :alternate

  @doc """
  Fold a chunk of PTY output into the detector.

  Returns the updated state; read the result with `mode/1`. Later transitions in
  a chunk win, so a burst that enters and leaves the alternate screen settles on
  whichever came last.
  """
  @spec scan(t(), binary()) :: t()
  def scan(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    {mode, pending} = walk(state.pending <> chunk, state.mode)
    %{state | mode: mode, pending: pending}
  end

  defp walk(binary, mode) do
    case :binary.match(binary, @csi_private) do
      :nomatch ->
        {mode, carry(binary)}

      {pos, len} ->
        rest = binary_part(binary, pos + len, byte_size(binary) - pos - len)

        case take_sequence(rest, "") do
          :incomplete ->
            # Hold the partial sequence (from the ESC) until the rest arrives.
            {mode, carry_from(binary, pos)}

          {:mode, params, final, tail} ->
            walk(tail, apply_mode(mode, params, final))

          {:other, tail} ->
            walk(tail, mode)
        end
    end
  end

  # Consume the parameter bytes of a private-mode sequence, then its final byte.
  defp take_sequence(<<c, rest::binary>>, params) when c in ?0..?9 or c == ?; do
    take_sequence(rest, params <> <<c>>)
  end

  defp take_sequence(<<?h, rest::binary>>, params), do: {:mode, params, :set, rest}
  defp take_sequence(<<?l, rest::binary>>, params), do: {:mode, params, :reset, rest}
  # Some other final byte: a private-mode sequence we don't care about.
  defp take_sequence(<<_, rest::binary>>, _params), do: {:other, rest}
  defp take_sequence(<<>>, _params), do: :incomplete

  defp apply_mode(mode, params, final) do
    if params |> String.split(";", trim: true) |> Enum.any?(&(&1 in @alt_modes)) do
      if final == :set, do: :alternate, else: :normal
    else
      mode
    end
  end

  defp carry_from(binary, pos) do
    binary |> binary_part(pos, byte_size(binary) - pos) |> cap()
  end

  # Keep a trailing partial "\e[?" so a sequence straddling two chunks is still
  # recognized once the remainder arrives.
  defp carry(binary) do
    size = byte_size(binary)

    cond do
      size >= 2 and binary_part(binary, size - 2, 2) == "\e[" -> "\e["
      size >= 1 and binary_part(binary, size - 1, 1) == "\e" -> "\e"
      true -> ""
    end
  end

  defp cap(binary) when byte_size(binary) <= @max_pending, do: binary
  defp cap(_binary), do: ""
end
