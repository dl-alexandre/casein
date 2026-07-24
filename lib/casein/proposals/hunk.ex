defmodule Casein.Proposals.Hunk do
  @moduledoc "Helpers for unified-diff hunk ranges."

  @type range :: {non_neg_integer(), non_neg_integer()}
  @type t :: %{old_range: range(), new_range: range()}

  @doc """
  Two `(start, count)` ranges overlap if their line spans intersect.

  A zero-count range means the hunk inserts/deletes at a position; we treat
  it as covering one line so an "insert at line N" and a "modify at line N"
  collide rather than slip past each other.
  """
  @spec overlap?(range(), range()) :: boolean()
  def overlap?({s1, c1}, {s2, c2}) do
    e1 = s1 + max(c1, 1)
    e2 = s2 + max(c2, 1)
    s1 < e2 and s2 < e1
  end

  @doc "Pairs of overlapping hunks between two lists, comparing on `old_range`."
  def overlaps(proposal_hunks, workspace_hunks) do
    for ph <- proposal_hunks,
        wh <- workspace_hunks,
        overlap?(ph.old_range, wh.old_range),
        do: %{proposal: ph, workspace: wh}
  end
end
