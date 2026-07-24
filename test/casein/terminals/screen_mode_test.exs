defmodule Casein.Terminals.ScreenModeTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.ScreenMode

  defp mode_after(chunks) do
    chunks
    |> List.wrap()
    |> Enum.reduce(ScreenMode.new(), &ScreenMode.scan(&2, &1))
    |> ScreenMode.mode()
  end

  test "starts on the normal screen" do
    assert ScreenMode.mode(ScreenMode.new()) == :normal
    refute ScreenMode.alternate?(ScreenMode.new())
  end

  test "plain output never leaves the normal screen" do
    assert mode_after("devbox@ip:~$ ls\r\nREADME.md\r\n") == :normal
  end

  test "enters and leaves the alternate screen on 1049" do
    assert mode_after("\e[?1049h") == :alternate
    assert mode_after(["\e[?1049h", "\e[?1049l"]) == :normal
  end

  test "recognizes the legacy 47 and 1047 toggles" do
    assert mode_after("\e[?47h") == :alternate
    assert mode_after("\e[?1047h") == :alternate
    assert mode_after(["\e[?1047h", "\e[?1047l"]) == :normal
  end

  test "handles the switch buried in real output" do
    # What a TUI actually emits on startup: hide cursor, switch, clear, draw.
    boot = "\e[?25l\e[?1049h\e[2J\e[H┌── Claude Code ──┐"
    assert mode_after(boot) == :alternate
  end

  test "the last transition in a chunk wins" do
    assert mode_after("\e[?1049h...\e[?1049l...\e[?1049h") == :alternate
    assert mode_after("\e[?1049h...\e[?1049l") == :normal
  end

  test "a sequence split across PTY chunks is still recognized" do
    # The pane worker coalesces chunks, but a flush boundary can still land
    # anywhere. Every split point must survive.
    seq = "\e[?1049h"

    for split <- 1..(byte_size(seq) - 1) do
      head = binary_part(seq, 0, split)
      tail = binary_part(seq, split, byte_size(seq) - split)

      assert mode_after([head, tail]) == :alternate,
             "split after #{split} byte(s) lost the switch"
    end
  end

  test "a split ESC before ordinary output does not wedge the parser" do
    assert mode_after(["output\e", "[?1049h"]) == :alternate
    assert mode_after(["output\e[", "?1049h"]) == :alternate
  end

  test "unrelated private modes leave the screen mode alone" do
    # Mouse reporting, bracketed paste, cursor visibility — all private modes.
    assert mode_after("\e[?1000h\e[?2004h\e[?25l") == :normal
    assert mode_after(["\e[?1049h", "\e[?1000h\e[?2004h"]) == :alternate
  end

  test "does not mistake 1049 appearing as a substring of another param" do
    # 21049 and 10490 are not the alternate screen.
    assert mode_after("\e[?21049h") == :normal
    assert mode_after("\e[?10490h") == :normal
  end

  test "handles multi-parameter private mode sequences" do
    assert mode_after("\e[?1049;25h") == :alternate
    assert mode_after(["\e[?1049h", "\e[?1049;25l"]) == :normal
  end

  test "a private-mode sequence with a non-toggle final byte is ignored" do
    # e.g. DECRQM ("\e[?1049$p") asks about the mode rather than setting it.
    assert mode_after("\e[?1049$p") == :normal
  end

  test "the carry buffer stays bounded against a stream that never completes" do
    state =
      Enum.reduce(1..200, ScreenMode.new(), fn _, acc ->
        ScreenMode.scan(acc, "\e[?" <> String.duplicate("1", 100))
      end)

    assert byte_size(state.pending) <= 64
    assert ScreenMode.mode(state) == :normal
  end
end
