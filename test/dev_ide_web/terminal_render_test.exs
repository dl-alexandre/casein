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

  test "render frame telemetry includes duration, size, and changed row counts" do
    handler_id = "terminal-render-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:dev_ide, :terminal, :render_frame],
      fn event, measurements, metadata, _cfg ->
        send(test_pid, {:render_frame_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    TerminalRender.build_payload(
      "ghostty-pane-1",
      cells("ac"),
      cursor(),
      %{mode: "none"},
      %{offset: 0},
      false,
      previous_cells: cells("ab"),
      frame_seq: 3,
      frame_epoch: 2
    )

    assert_receive {:render_frame_telemetry, [:dev_ide, :terminal, :render_frame], measurements,
                    metadata}

    assert measurements.count == 1
    assert measurements.rows == 1
    assert measurements.cells == 2
    assert measurements.changed_rows == 1
    assert measurements.payload_bytes > 0
    assert is_integer(measurements.duration_us)

    assert metadata.id == "ghostty-pane-1"
    assert metadata.full_frame? == false
    assert metadata.sequenced? == true
    assert metadata.empty_incremental? == false
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
