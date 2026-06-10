defmodule DevIDE.Proposals.ConflictAnalyzer do
  @moduledoc """
  Compare a parsed proposal against the current working-tree git diff and
  produce a `DevIDE.Proposals.Analysis`.

  Risk rules (highest wins):
    * `:invalid`  — proposal isn't `:parsed` or its diff cannot be re-parsed
                    with hunks.
    * `:conflict` — any proposal hunk overlaps a workspace hunk on the same
                    file, OR the proposal `:delete`s a path the workspace
                    has also modified, OR the proposal `:add`s a path that
                    already shows up in the workspace diff.
    * `:overlap`  — proposal touches a file that the workspace also touches,
                    but no hunk-range overlap.
    * `:clean`    — no path overlap with the workspace diff.
  """

  alias DevIDE.Proposals.{Analysis, Hunk, Proposal, UnifiedDiff}
  alias DevIDE.Git

  @spec analyze(String.t(), Proposal.t()) :: Analysis.t()
  def analyze(root, %Proposal{status: :parsed, diff: diff}) when is_binary(diff) do
    with {:ok, proposal_changes} <- UnifiedDiff.parse_with_hunks(diff, root),
         {:ok, workspace_diff} <- Git.diff_all(root) do
      workspace_changes = parse_workspace(workspace_diff, root)
      build(proposal_changes, workspace_changes)
    else
      {:error, reason} ->
        %Analysis{
          risk: :invalid,
          reason: "could not analyze: #{inspect(reason)}"
        }
    end
  end

  def analyze(_root, %Proposal{status: status, error: err}) do
    %Analysis{
      risk: :invalid,
      reason: err || "proposal status: #{status}"
    }
  end

  defp parse_workspace(diff, root) do
    case UnifiedDiff.parse_with_hunks(diff, root) do
      {:ok, list} -> Map.new(list, fn c -> {c.path, c} end)
      _ -> %{}
    end
  end

  defp build(proposal_changes, workspace_index) do
    files =
      Enum.map(proposal_changes, fn change ->
        case Map.get(workspace_index, change.path) do
          nil ->
            %{
              path: change.path,
              kind: change.kind,
              status: :no_workspace_change,
              hunks: []
            }

          ws ->
            classify_overlap(change, ws)
        end
      end)

    overlapping = Enum.filter(files, &(&1.status in [:overlap, :conflict]))
    conflict? = Enum.any?(files, &(&1.status == :conflict))
    overlap? = Enum.any?(files, &(&1.status == :overlap))

    risk =
      cond do
        conflict? -> :conflict
        overlap? -> :overlap
        true -> :clean
      end

    %Analysis{
      risk: risk,
      reason: reason_for(risk),
      files: files,
      overlapping_files: Enum.map(overlapping, & &1.path),
      files_count: length(proposal_changes)
    }
  end

  defp classify_overlap(%{kind: :delete} = c, _ws),
    do: %{path: c.path, kind: :delete, status: :conflict, hunks: []}

  defp classify_overlap(%{kind: :add} = c, _ws),
    do: %{path: c.path, kind: :add, status: :conflict, hunks: []}

  defp classify_overlap(%{kind: :modify, hunks: ph} = c, %{hunks: wh}) do
    overlaps = Hunk.overlaps(ph, wh)

    %{
      path: c.path,
      kind: :modify,
      status: if(overlaps == [], do: :overlap, else: :conflict),
      hunks: overlaps
    }
  end

  defp reason_for(:clean), do: "no path overlap with workspace changes"
  defp reason_for(:overlap), do: "proposal touches files the workspace also modifies"
  defp reason_for(:conflict), do: "proposal hunks collide with workspace changes"
end
