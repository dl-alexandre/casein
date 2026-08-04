defmodule CaseinMob.LayoutTest do
  use ExUnit.Case, async: true

  alias CaseinMob.Layout

  defp node(type, props, children \\ []),
    do: %{type: type, props: props, children: children}

  defp text(label), do: node(:text, %{text: label})

  test "a column gap becomes real spacers between children" do
    tree = Layout.materialize(node(:column, %{gap: 12}, [text("a"), text("b"), text("c")]))

    assert [
             %{type: :text},
             %{type: :spacer, props: %{size: 12}},
             %{type: :text},
             %{type: :spacer, props: %{size: 12}},
             %{type: :text}
           ] = tree.children

    # Dropped, so a renderer that later implements `gap` cannot double-space.
    refute Map.has_key?(tree.props, :gap)
  end

  test "rows are spaced the same way" do
    tree = Layout.materialize(node(:row, %{gap: 8}, [text("a"), text("b")]))

    assert [%{type: :text}, %{type: :spacer, props: %{size: 8}}, %{type: :text}] = tree.children
  end

  test "spacing tokens resolve against the active theme" do
    Mob.Theme.set([])
    expected = Mob.Theme.current() |> Mob.Theme.spacing_map() |> Map.fetch!(:space_md)

    tree = Layout.materialize(node(:column, %{gap: :space_md}, [text("a"), text("b")]))

    assert [_, %{type: :spacer, props: %{size: ^expected}}, _] = tree.children
    assert is_number(expected) and expected > 0
  end

  test "nesting is materialised at every level" do
    tree =
      Layout.materialize(
        node(:column, %{gap: 4}, [
          node(:row, %{gap: 2}, [text("a"), text("b")]),
          text("c")
        ])
      )

    assert [%{type: :row} = row, %{type: :spacer, props: %{size: 4}}, %{type: :text}] =
             tree.children

    assert [_, %{type: :spacer, props: %{size: 2}}, _] = row.children
  end

  test "nil children are dropped before spacing, so a hidden child leaves no double gap" do
    tree = Layout.materialize(node(:column, %{gap: 6}, [text("a"), nil, text("b")]))

    assert [%{type: :text}, %{type: :spacer}, %{type: :text}] = tree.children
  end

  test "a gap with nothing to separate changes nothing" do
    assert Layout.materialize(node(:column, %{gap: 10}, [text("only")])).children == [
             text("only")
           ]

    assert Layout.materialize(node(:column, %{gap: 10}, [])).children == []
  end

  test "a box keeps its children adjacent — its children stack in z-order" do
    tree = Layout.materialize(node(:box, %{gap: 10}, [text("a"), text("b")]))

    assert [%{type: :text}, %{type: :text}] = tree.children
  end

  test "unusable gap values are left alone rather than emitting a zero spacer" do
    for value <- [0, -4, "12", :not_a_token] do
      tree = Layout.materialize(node(:column, %{gap: value}, [text("a"), text("b")]))
      assert [%{type: :text}, %{type: :text}] = tree.children
    end
  end

  test "materialising twice is a no-op" do
    once = Layout.materialize(node(:column, %{gap: 12}, [text("a"), text("b")]))
    twice = Layout.materialize(once)

    assert once == twice
  end

  test "props other than gap survive untouched" do
    tree =
      Layout.materialize(
        node(:column, %{gap: 12, fill_width: true, background: :surface}, [text("a"), text("b")])
      )

    assert tree.props.fill_width
    assert tree.props.background == :surface
  end
end
