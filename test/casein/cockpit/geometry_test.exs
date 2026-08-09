defmodule Casein.Cockpit.GeometryTest do
  use ExUnit.Case, async: true

  alias Casein.Cockpit.Geometry

  test "terminal_only is a leaf with no inspector" do
    geo = Geometry.terminal_only()
    assert geo == %{kind: :region, id: :terminal}
    refute Geometry.inspector_open?(geo)
    assert Geometry.terminal_basis_percent(geo) == nil
    assert Geometry.inspector_basis_percent(geo) == nil
  end

  test "terminal_inspector builds a binary split tree" do
    geo = Geometry.terminal_inspector(:right, 0.4)

    assert geo.kind == :split
    assert geo.direction == :horizontal
    assert_in_delta geo.ratio, 0.6, 0.0001
    assert geo.first == %{kind: :region, id: :terminal}
    assert geo.second == %{kind: :region, id: :inspector}

    assert Geometry.inspector_open?(geo)
    assert Geometry.placement(geo) == :right
    assert_in_delta Geometry.inspector_fraction(geo), 0.4, 0.0001
    assert Geometry.terminal_basis_percent(geo) == 60.0
    assert Geometry.inspector_basis_percent(geo) == 40.0
  end

  test "bottom placement is a vertical split" do
    geo = Geometry.terminal_inspector(:bottom, 0.3)
    assert geo.direction == :vertical
    assert Geometry.placement(geo) == :bottom
    assert_in_delta geo.ratio, 0.7, 0.0001
  end

  test "for_inspectors restores terminal-only when the list is empty" do
    assert Geometry.for_inspectors([]) == Geometry.terminal_only()

    open = Geometry.for_inspectors([%{id: "a"}], placement: :right, fraction: 0.4)
    assert Geometry.inspector_open?(open)
  end

  test "ratio is clamped" do
    tiny = Geometry.terminal_inspector(:right, 0.01)
    assert tiny.ratio == 0.85

    huge = Geometry.terminal_inspector(:right, 0.99)
    assert huge.ratio == 0.15
  end
end
