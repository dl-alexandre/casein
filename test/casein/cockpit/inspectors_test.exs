defmodule Casein.Cockpit.InspectorsTest do
  use ExUnit.Case, async: true

  alias Casein.Cockpit.Geometry
  alias Casein.Cockpit.Inspectors

  test "open/close lifecycle recomputes geometry" do
    {panes, geo} = Inspectors.open([], %{kind: :diff, title: "Diff", id: "insp-diff"})
    assert length(panes) == 1
    assert hd(panes).id == "insp-diff"
    assert hd(panes).kind == :diff
    assert Geometry.inspector_open?(geo)
    assert Geometry.placement(geo) == :right

    {panes, geo} = Inspectors.close(panes, "insp-diff")
    assert panes == []
    assert geo == Geometry.terminal_only()
  end

  test "open replaces same id rather than duplicating" do
    {panes, _} = Inspectors.open([], %{id: "x", kind: :diff, title: "A"})
    {panes, _} = Inspectors.open(panes, %{id: "x", kind: :diff, title: "B"})
    assert length(panes) == 1
    assert hd(panes).title == "B"
  end

  test "placement preference flows into geometry" do
    {_panes, geo} =
      Inspectors.open([], %{kind: :run, id: "r"}, placement: :bottom, fraction: 0.5)

    assert Geometry.placement(geo) == :bottom
    assert_in_delta Geometry.inspector_fraction(geo), 0.5, 0.0001
  end

  test "request_open broadcasts on the workspace topic" do
    ws = "ws-insp-#{System.unique_integer([:positive])}"
    :ok = Inspectors.subscribe(ws)
    :ok = Inspectors.request_open(ws, kind: :diff, title: "Side", id: "d1")

    assert_receive {:inspector_open, attrs}
    assert attrs[:kind] == :diff or attrs["kind"] == :diff or Map.get(attrs, :kind) == :diff
    assert attrs[:id] == "d1" or attrs["id"] == "d1" or Map.get(attrs, :id) == "d1"
  end

  test "initial_assigns is terminal-only" do
    assigns = Inspectors.initial_assigns()
    assert assigns.inspector_panes == []
    assert assigns.cockpit_geometry == Geometry.terminal_only()
    assert assigns.inspector_placement == :right
  end

  test "serialize/restore re-derives path only (no content snapshot)" do
    {panes, _} =
      Inspectors.open([], %{kind: :diff, id: "insp-diff", title: "lib/foo.ex", path: "lib/foo.ex"})

    assert Inspectors.serialize(panes) == [
             %{"type" => "inspector", "kind" => "diff", "path" => "lib/foo.ex"}
           ]

    assert Inspectors.primary_diff_path(panes) == "lib/foo.ex"
    assert Inspectors.diff_open?(panes)

    {restored, geo} = Inspectors.restore(Inspectors.serialize(panes))
    assert Geometry.inspector_open?(geo)
    assert Inspectors.primary_diff_path(restored) == "lib/foo.ex"
    # Fresh id — identity is not durable.
    refute hd(restored).id == hd(panes).id
  end

  test "serialize omits path when unscoped; restore rejects non-lists" do
    {panes, _} = Inspectors.open([], %{kind: :diff, id: "d", title: "Diff"})
    assert Inspectors.serialize(panes) == [%{"type" => "inspector", "kind" => "diff"}]
    assert Inspectors.primary_diff_path(panes) == nil

    {empty, geo} = Inspectors.restore(nil)
    assert empty == []
    assert geo == Geometry.terminal_only()
  end
end
