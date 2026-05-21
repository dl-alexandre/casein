defmodule DevIdeWeb.WorkspaceLive.PaneLayout do
  @moduledoc """
  Pure functions for the recursive tmux-style split layout tree used by
  WorkspaceLive.Show.

  The single source of truth for pane arrangement and split ratios.
  Extracted so the LiveView stays focused on wiring/events and the
  layout algorithms are easy to test and reuse.

  Client-side (SplitResizer hook) performs live pixel-based min-size clamping
  (120 px) during drag and computes the ratio ultimately sent to the server
  functions here. Server-side helpers apply only the 10–90 % safety clamp for
  non-drag paths (keyboard, equalize, reset, initial splits) and for re-renders.
  The resulting layout is always usable because the interactive path already
  protects usability.
  """

  @type pane_id :: String.t()

  @type layout_node ::
          {:pane, pane_id}
          | {:split, direction :: :horizontal | :vertical, children :: [layout_node],
             sizes :: [float()]}

  @doc "Replace a leaf pane with a binary split (used on split_right / split_down)."
  def split_layout(layout, target_pane_id, new_pane_id, direction) do
    case layout do
      {:pane, ^target_pane_id} ->
        {:split, direction, [{:pane, target_pane_id}, {:pane, new_pane_id}], [0.5, 0.5]}

      {:split, dir, children, sizes} ->
        new_children =
          Enum.map(children, fn child ->
            split_layout(child, target_pane_id, new_pane_id, direction)
          end)

        {:split, dir, new_children, sizes}

      other ->
        other
    end
  end

  @doc "Remove a pane (and its ancestor splits if they collapse to a single child)."
  def remove_pane_from_layout({:pane, id}, pane_id) when id == pane_id, do: nil
  def remove_pane_from_layout({:pane, id}, _), do: {:pane, id}

  def remove_pane_from_layout({:split, dir, children, sizes}, pane_id) do
    new_children =
      Enum.map(children, &remove_pane_from_layout(&1, pane_id)) |> Enum.reject(&is_nil/1)

    case new_children do
      [] ->
        nil

      [only] ->
        only

      _ ->
        new_sizes =
          sizes
          |> Enum.take(length(new_children))
          |> normalize_sizes()

        {:split, dir, new_children, new_sizes}
    end
  end

  def normalize_sizes([]), do: []

  def normalize_sizes(sizes) do
    total = Enum.sum(sizes)

    if total > 0 do
      Enum.map(sizes, &(&1 / total))
    else
      n = length(sizes)
      List.duplicate(1.0 / n, n)
    end
  end

  @doc "First (leftmost/topmost) pane id in the tree, used for focus after close."
  def first_pane_id({:pane, id}), do: id
  def first_pane_id({:split, _, [first | _], _}), do: first_pane_id(first)
  def first_pane_id(_), do: nil

  @doc "Count leaves for the 'N panes' badge and guards."
  def count_panes({:pane, _}), do: 1

  def count_panes({:split, _, children, _}),
    do: Enum.reduce(children, 0, fn child, acc -> acc + count_panes(child) end)

  def count_panes(_), do: 0

  @doc """
  Resize the specific adjacent pair identified by their first-pane ids.
  Used by the drag resizer and keyboard nudge. Applies the 10–90 % safety clamp.

  Client-side drag (SplitResizer) already enforces dynamic pixel min-size
  (≈120 px) and sends a pre-clamped ratio; this function only provides the
  final server-side guard for other callers and re-renders.
  """
  def resize_split(layout, left_id, right_id, new_left_ratio) do
    ratio = max(0.1, min(0.9, new_left_ratio))

    case layout do
      {:split, dir, children, sizes} ->
        matched? =
          children
          |> Enum.zip(tl(children))
          |> Enum.any?(fn {c_left, c_right} ->
            first_pane_id(c_left) == left_id and first_pane_id(c_right) == right_id
          end)

        if matched? do
          new_sizes =
            children
            |> Enum.with_index()
            |> Enum.map(fn {child, i} ->
              cond do
                i == 0 and first_pane_id(child) == left_id and
                    first_pane_id(Enum.at(children, 1)) == right_id ->
                  ratio

                i > 0 and first_pane_id(Enum.at(children, i - 1)) == left_id and
                    first_pane_id(child) == right_id ->
                  1 - ratio

                true ->
                  Enum.at(sizes, i, 1.0 / max(length(children), 1))
              end
            end)
            |> normalize_sizes()

          {:split, dir, children, new_sizes}
        else
          new_children = Enum.map(children, &resize_split(&1, left_id, right_id, ratio))
          {:split, dir, new_children, sizes}
        end

      {:pane, _} ->
        layout

      _ ->
        layout
    end
  end

  @doc "Set every split node in the tree to equal child ratios (for the reset button)."
  def equalize_layout({:pane, _} = node), do: node

  def equalize_layout({:split, dir, children, _sizes}) do
    n = max(length(children), 1)
    eq = List.duplicate(1.0 / n, n)
    {:split, dir, Enum.map(children, &equalize_layout/1), eq}
  end

  def equalize_layout(other), do: other

  @doc "Rotate split direction at every split node, preserving pane order and sizes."
  def cycle_layout({:pane, _} = node), do: node

  def cycle_layout({:split, dir, children, sizes}) do
    next_dir = if dir == :horizontal, do: :vertical, else: :horizontal
    {:split, next_dir, Enum.map(children, &cycle_layout/1), sizes}
  end

  def cycle_layout(other), do: other

  @doc "Collect all leaf pane ids (used by persistence restore validation)."
  def collect_pane_ids({:pane, id}), do: [id]
  def collect_pane_ids({:split, _, children, _}), do: Enum.flat_map(children, &collect_pane_ids/1)
  def collect_pane_ids(_), do: []

  @doc "Return the next pane id in layout order, wrapping at the end."
  def next_pane_id(layout, current_id) do
    sibling_pane_id(layout, current_id, 1)
  end

  @doc "Return the previous pane id in layout order, wrapping at the beginning."
  def previous_pane_id(layout, current_id) do
    sibling_pane_id(layout, current_id, -1)
  end

  @doc """
  Re-hydrate a JSON-decoded layout (from localStorage) back into the internal
  tuple form. Returns nil for anything malformed.
  """
  def from_json_layout(["pane", id]) when is_binary(id), do: {:pane, id}

  def from_json_layout(["split", dir, children, sizes])
      when dir in ["horizontal", "vertical"] and is_list(children) and is_list(sizes) do
    d = if dir == "horizontal", do: :horizontal, else: :vertical

    child_nodes = Enum.map(children, &from_json_layout/1)

    if Enum.any?(child_nodes, &is_nil/1) do
      nil
    else
      {:split, d, child_nodes,
       Enum.map(sizes, fn s -> if is_number(s), do: s * 1.0, else: 0.5 end)}
    end
  end

  def from_json_layout(_), do: nil

  @doc """
  Convert the internal layout tuple into the JSON-persistence array form
  expected by the client (and safe for Jason / push_event).
  """
  def to_json_layout({:pane, id}), do: ["pane", id]

  def to_json_layout({:split, dir, children, sizes}) do
    d = if dir == :horizontal, do: "horizontal", else: "vertical"
    ["split", d, Enum.map(children, &to_json_layout/1), sizes]
  end

  def to_json_layout(other), do: other

  @doc """
  Convert the recursive layout to a plain nested map for Tidewave, IEx, and
  dev tooling inspection.
  """
  def to_debug({:pane, id}), do: %{type: "pane", id: id}

  def to_debug({:split, dir, children, sizes}) do
    %{
      type: "split",
      direction: Atom.to_string(dir),
      sizes: sizes,
      children: Enum.map(children, &to_debug/1)
    }
  end

  def to_debug(_), do: %{type: "invalid"}

  @doc """
  Find a neighboring pane in the given direction by traversing the split tree.

  Only moves between direct siblings of a split whose axis matches the
  requested direction (:horizontal for left/right, :vertical for up/down).
  Returns nil when there is no neighbor on that axis/edge.

  This gives predictable "within current row or column" navigation
  that works with arbitrarily nested splits.
  """
  def neighbor(layout, current_id, dir) when dir in [:left, :right, :up, :down] do
    axis = if dir in [:left, :right], do: :horizontal, else: :vertical
    delta = if dir in [:left, :up], do: -1, else: +1
    find_neighbor(layout, current_id, axis, delta)
  end

  defp find_neighbor({:pane, _}, _current_id, _axis, _delta), do: nil

  defp find_neighbor({:split, split_dir, children, _sizes}, current_id, axis, delta) do
    if split_dir == axis do
      # Look for the child that contains the current pane, then step by delta
      idx =
        Enum.find_index(children, fn child ->
          contains_pane?(child, current_id)
        end)

      case idx do
        nil ->
          nil

        i ->
          new_i = i + delta

          if new_i >= 0 and new_i < length(children) do
            first_pane_id(Enum.at(children, new_i))
          else
            nil
          end
      end
    else
      # Descend into the branch that holds the current pane
      Enum.find_value(children, fn child ->
        if contains_pane?(child, current_id) do
          find_neighbor(child, current_id, axis, delta)
        end
      end)
    end
  end

  defp find_neighbor(_other, _current_id, _axis, _delta), do: nil

  defp contains_pane?({:pane, id}, target_id), do: id == target_id

  defp contains_pane?({:split, _, children, _}, target_id),
    do: Enum.any?(children, &contains_pane?(&1, target_id))

  defp contains_pane?(_, _), do: false

  defp sibling_pane_id(layout, current_id, delta) when delta in [-1, 1] do
    pane_ids = collect_pane_ids(layout)

    case Enum.find_index(pane_ids, &(&1 == current_id)) do
      nil ->
        nil

      idx when pane_ids != [] ->
        Enum.at(pane_ids, rem(idx + delta + length(pane_ids), length(pane_ids)))
    end
  end
end
