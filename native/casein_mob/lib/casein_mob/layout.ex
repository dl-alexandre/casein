defmodule CaseinMob.Layout do
  @moduledoc """
  Makes `gap:` real.

  Every screen in this app spaces its rows and columns with `gap:` — 23 uses in
  the session dashboard alone. **Neither native renderer reads that prop.**
  SwiftUI builds `VStack(spacing: 0)` / `HStack(spacing: 0)` and Compose builds
  a bare `Column`/`Row` with no arrangement, so the value is dropped and every
  element sits flush against its neighbour on device. Unit tests never caught it
  because the prop is present and correct in the view tree; only the pixels are
  wrong.

  The renderers *do* honor a `Spacer` with a `size`, which is the supported way
  to space children. `materialize/1` walks a finished view tree and rewrites
  each `gap`-bearing row/column into the same layout expressed with real
  spacers, so existing screens keep their declarative `gap:` and start rendering
  the spacing they always asked for.

      def render(assigns) do
        CaseinMob.Layout.materialize(%{type: :column, props: %{gap: 12}, ...})
      end

  Notes:

    * Spacing tokens (`:space_md`) are resolved here against the active theme.
      `Mob.Renderer` resolves them for `padding`/`gap`, but a spacer's `size` is
      not in its spacing-prop list, so an unresolved atom would reach the
      native side and be ignored — trading one silent no-op for another.
    * `gap` is dropped from the props it materialises, so a future renderer that
      *does* implement it cannot double-space the layout.
    * Only nodes with two or more children change: a gap with nothing to
      separate is a no-op, and `nil` children are dropped first so a conditional
      child cannot leave a double gap behind.
  """

  @spacing_tokens ~w(space_xs space_sm space_md space_lg space_xl)a

  @doc """
  Rewrite every `gap:` in `tree` into real `Spacer` nodes.

  Idempotent: a tree that has already been materialised carries no `gap` props
  and is returned unchanged.
  """
  @spec materialize(map() | list() | nil) :: map() | list() | nil
  def materialize(tree), do: walk(tree, spacing_map())

  defp walk(nil, _spacing), do: nil

  defp walk(nodes, spacing) when is_list(nodes) do
    nodes
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&walk(&1, spacing))
  end

  defp walk(%{type: type} = node, spacing) do
    children =
      node
      |> Map.get(:children, [])
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&walk(&1, spacing))

    props = Map.get(node, :props, %{}) || %{}

    case gap_size(type, props, spacing) do
      nil ->
        %{node | children: children} |> put_props(props)

      size ->
        %{node | children: interleave(children, size)}
        |> put_props(Map.delete(props, :gap))
    end
  end

  defp walk(other, _spacing), do: other

  # Only rows and columns lay children out along an axis. A `Box` stacks its
  # children in z-order, so a spacer between them would be drawn on top of the
  # content rather than separating it.
  defp gap_size(type, props, spacing) when type in [:row, :column] do
    case Map.get(props, :gap) do
      nil -> nil
      value -> resolve(value, spacing)
    end
  end

  defp gap_size(_type, _props, _spacing), do: nil

  defp resolve(value, _spacing) when is_number(value) and value > 0, do: value

  defp resolve(value, spacing) when value in @spacing_tokens do
    case Map.get(spacing, value) do
      size when is_number(size) and size > 0 -> size
      _ -> nil
    end
  end

  defp resolve(_value, _spacing), do: nil

  defp interleave([], _size), do: []
  defp interleave([only], _size), do: [only]

  defp interleave(children, size) do
    Enum.intersperse(children, %{type: :spacer, props: %{size: size}, children: []})
  end

  defp put_props(node, props), do: %{node | props: props}

  # The theme is read once per render rather than per node.
  defp spacing_map do
    Mob.Theme.current() |> Mob.Theme.spacing_map()
  rescue
    # A screen rendered before the theme is set (or in a bare unit test) still
    # materialises numeric gaps; only token gaps need the theme.
    _ -> %{}
  end
end
