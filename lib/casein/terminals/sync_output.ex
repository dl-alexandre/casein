defmodule Casein.Terminals.SyncOutput do
  @moduledoc """
  DEC private mode 2026 (synchronized output) detection for PTY byte streams.

  Apps wrap an atomic screen update between BSU (`CSI ? 2026 h`) and ESU
  (`CSI ? 2026 l`). `PaneWorker` uses this to hold a rendered frame back until
  the update closes, so viewers never see a mid-redraw tear.

  Only the canonical single-mode form is recognized; sequences split across
  flush windows are not stitched (the worst case is a one-window-late frame,
  not corruption).
  """

  @bsu "\e[?2026h"
  @esu "\e[?2026l"

  @doc """
  Synchronized-output state after applying `binary`, given the prior `current`.

  The last BSU/ESU toggle in the chunk wins; with no toggle present the state
  is unchanged.
  """
  @spec active_after?(binary(), boolean()) :: boolean()
  def active_after?(binary, current) when is_binary(binary) and is_boolean(current) do
    case {last_match(binary, @bsu), last_match(binary, @esu)} do
      {nil, nil} -> current
      {_begin, nil} -> true
      {nil, _end} -> false
      {begin_pos, end_pos} -> begin_pos > end_pos
    end
  end

  defp last_match(binary, pattern) do
    case :binary.matches(binary, pattern) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
