defmodule DevIdeWeb.TerminalRenderTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.TerminalRender

  test "forced full frames include cells and sequencing metadata" do
    payload =
      TerminalRender.build_payload(
        "ghostty-pane-1",
        cells("ab"),
        cursor(),
        :mouse,
        %{offset: 0},
        false,
        force_full?: true,
        frame_seq: 0,
        frame_epoch: 7
      )

    assert payload.full_frame == true
    assert payload.frame_seq == 0
    assert payload.frame_epoch == 7
    assert payload.cells == [[["a", [1, 2, 3], nil, []], ["b", [1, 2, 3], nil, []]]]
    refute Map.has_key?(payload, :rows)
  end

  test "unchanged shapes produce incremental row diffs with sequencing metadata" do
    previous = cells("ab")
    current = cells("ac")

    payload =
      TerminalRender.build_payload(
        "ghostty-pane-1",
        current,
        cursor(),
        :mouse,
        %{offset: 0},
        false,
        previous_cells: previous,
        frame_seq: 3,
        frame_epoch: 2
      )

    assert payload.full_frame == false
    assert payload.frame_seq == 3
    assert payload.frame_epoch == 2

    assert payload.rows == [
             %{index: 0, cells: [["a", [1, 2, 3], nil, []], ["c", [1, 2, 3], nil, []]]}
           ]

    refute Map.has_key?(payload, :cells)
  end

  test "shape changes force a full frame" do
    previous = cells("ab")
    current = cells("abc")

    payload =
      TerminalRender.build_payload(
        "ghostty-pane-1",
        current,
        cursor(),
        :mouse,
        %{offset: 0},
        false,
        previous_cells: previous,
        frame_seq: 0,
        frame_epoch: 8
      )

    assert payload.full_frame == true
    assert payload.frame_epoch == 8

    assert payload.cells == [
             [["a", [1, 2, 3], nil, []], ["b", [1, 2, 3], nil, []], ["c", [1, 2, 3], nil, []]]
           ]
  end

  defp cursor, do: %{x: 0, y: 0, color: {9, 8, 7}}

  defp cells(text) do
    [
      text
      |> String.graphemes()
      |> Enum.map(&{&1, {1, 2, 3}, nil, []})
    ]
  end
end
