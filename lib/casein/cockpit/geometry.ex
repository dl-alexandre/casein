defmodule Casein.Cockpit.Geometry do
  @moduledoc """
  Cockpit layout geometry as a tree.

  A node is either a leaf (`:region`) or a binary split (`:split` with direction,
  ratio, and two children). Today the only live shape is a single terminal |
  inspector split, but the tree is the model so a larger geometry change grows
  this module rather than replacing it (issue #690 / epic #689).
  """

  @type direction :: :horizontal | :vertical
  @type region_id :: :terminal | :inspector

  @type t ::
          %{kind: :region, id: region_id()}
          | %{
              kind: :split,
              direction: direction(),
              ratio: float(),
              first: t(),
              second: t()
            }

  @default_ratio 0.6
  @min_ratio 0.15
  @max_ratio 0.85

  @doc "Full-bleed terminal — no inspector region."
  @spec terminal_only() :: t()
  def terminal_only, do: %{kind: :region, id: :terminal}

  @doc """
  Terminal | inspector split.

  `placement` is the inspector's side of the cockpit:
    * `:right`  → horizontal split, terminal first (left), inspector second
    * `:bottom` → vertical split, terminal first (top), inspector second

  `fraction` is the inspector's share of the parent (0..1); the terminal gets
  `1 - fraction`.
  """
  @spec terminal_inspector(atom(), number()) :: t()
  def terminal_inspector(placement, fraction \\ 0.4)

  def terminal_inspector(placement, fraction) do
    ratio = terminal_ratio(fraction)
    direction = direction_for(placement)

    %{
      kind: :split,
      direction: direction,
      ratio: ratio,
      first: %{kind: :region, id: :terminal},
      second: %{kind: :region, id: :inspector}
    }
  end

  @doc "True when the tree contains an `:inspector` leaf."
  @spec inspector_open?(t()) :: boolean()
  def inspector_open?(%{kind: :region, id: :inspector}), do: true
  def inspector_open?(%{kind: :region}), do: false

  def inspector_open?(%{kind: :split, first: first, second: second}) do
    inspector_open?(first) or inspector_open?(second)
  end

  def inspector_open?(_), do: false

  @doc "Inspector placement derived from a split, defaulting to `:right`."
  @spec placement(t()) :: :right | :bottom
  def placement(%{kind: :split, direction: :vertical}), do: :bottom
  def placement(%{kind: :split, direction: :horizontal}), do: :right
  def placement(_), do: :right

  @doc "Inspector fraction (second child's share) for a terminal|inspector split."
  @spec inspector_fraction(t()) :: float()
  def inspector_fraction(%{kind: :split, ratio: ratio}) when is_number(ratio) do
    clamp(1.0 - ratio)
  end

  def inspector_fraction(_), do: 0.4

  @doc "CSS flex basis percent for the terminal leaf given current geometry."
  @spec terminal_basis_percent(t()) :: float() | nil
  def terminal_basis_percent(%{kind: :split, ratio: ratio}) when is_number(ratio) do
    Float.round(ratio * 100, 2)
  end

  def terminal_basis_percent(_), do: nil

  @doc "CSS flex basis percent for the inspector leaf."
  @spec inspector_basis_percent(t()) :: float() | nil
  def inspector_basis_percent(%{kind: :split, ratio: ratio}) when is_number(ratio) do
    Float.round((1.0 - ratio) * 100, 2)
  end

  def inspector_basis_percent(_), do: nil

  @doc "Build geometry from open inspector count + placement/fraction prefs."
  @spec for_inspectors(list(), keyword()) :: t()
  def for_inspectors(inspectors, opts \\ []) when is_list(inspectors) do
    if inspectors == [] do
      terminal_only()
    else
      terminal_inspector(
        Keyword.get(opts, :placement, :right),
        Keyword.get(opts, :fraction, 0.4)
      )
    end
  end

  defp direction_for(:bottom), do: :vertical
  defp direction_for("bottom"), do: :vertical
  defp direction_for(_), do: :horizontal

  defp terminal_ratio(fraction) when is_number(fraction) do
    clamp(1.0 - fraction)
  end

  defp terminal_ratio(_), do: @default_ratio

  defp clamp(n) when is_number(n) do
    n
    |> max(@min_ratio)
    |> min(@max_ratio)
    |> then(&(&1 * 1.0))
  end
end
