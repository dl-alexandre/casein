defmodule Casein.Terminals.WorktreeDiffTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.WorktreeDiff

  @now ~U[2026-08-14 05:00:00Z]
  @ws "ws-1"
  @session "casein_ws-1_main"

  defp topology(panes, windows \\ nil) do
    windows =
      windows ||
        panes
        |> Enum.map(fn p ->
          %{
            id: Map.get(p, :window_id) || "@9",
            name: Map.get(p, :window_name) || "worker-demo",
            active: false
          }
        end)
        |> Enum.uniq_by(& &1.id)

    %{windows: windows, panes: panes}
  end

  defp pane(id, overrides \\ []) do
    Map.merge(
      %{
        id: id,
        window_id: "@9",
        window_name: "worker-demo",
        role: "agent",
        fleet_role: :worker,
        worktree_path: "/tmp/wt-worker"
      },
      Map.new(overrides)
    )
  end

  defp project(topo, opts \\ []) do
    WorktreeDiff.project(
      topo,
      Keyword.merge(
        [workspace_id: @ws, session: @session, pane: "%42", now: @now],
        opts
      )
    )
  end

  describe "project/2 identity and diff" do
    test "joins pane identity with a bounded unified diff" do
      patch = "diff --git a/lib/foo.ex b/lib/foo.ex\n+ok\n"

      diff = fn path ->
        assert path == "/tmp/wt-worker"
        {:ok, patch}
      end

      payload = project(topology([pane("%42")]), diff: diff)

      assert payload.found? == true
      assert payload.pane_id == "%42"
      assert payload.window_id == "@9"
      assert payload.worktree_path == "/tmp/wt-worker"
      assert payload.status_state == "ok"
      assert payload.diff == patch
      assert payload.byte_count == byte_size(patch)
      assert payload.truncated? == false
      assert payload.note =~ "M4.4"
    end

    test "successful empty diff is an honest empty patch" do
      payload = project(topology([pane("%42")]), diff: fn _ -> {:ok, ""} end)

      assert payload.status_state == "ok"
      assert payload.diff == ""
      assert payload.byte_count == 0
    end

    test "pane not found omits diff" do
      payload = project(topology([]), pane: "%99")

      assert payload.found? == false
      assert payload.status_state == "unknown"
      assert payload.unknown_reason == "pane_not_found"
      refute Map.has_key?(payload, :diff)
    end
  end

  describe "contract: unknown never looks like an empty patch" do
    test "diff error never emits diff: \"\"" do
      payload = project(topology([pane("%42")]), diff: fn _ -> :error end)

      assert payload.status_state == "unknown"
      assert payload.unknown_reason == "diff_failed"
      refute Map.has_key?(payload, :diff)
      refute Map.has_key?(payload, :byte_count)
    end

    test "missing worktree is unknown, not an empty patch" do
      payload = project(topology([pane("%42", worktree_path: nil)]))

      assert payload.status_state == "unknown"
      assert payload.unknown_reason == "no_worktree"
      refute Map.has_key?(payload, :diff)
    end

    test "payload does not invent path-contract / graph fields" do
      payload = project(topology([pane("%42")]), diff: fn _ -> {:ok, "+x\n"} end)

      forbid = [
        :orchestration_id,
        :task_id,
        :attempt_id,
        :contract_version,
        :path_contract,
        :forbidden_paths,
        :changed_paths,
        :worktree_status
      ]

      for key <- forbid do
        refute Map.has_key?(payload, key),
               "payload must not carry #{key} (out of scope for worktree_diff M4.4)"
      end
    end

    test "caps the diff and flags truncated? without dropping status_state ok" do
      body = String.duplicate("x", 65_536 + 20)
      payload = project(topology([pane("%42")]), diff: fn _ -> {:ok, body} end)

      assert payload.status_state == "ok"
      assert payload.truncated? == true
      assert payload.byte_count == 65_536
      assert byte_size(payload.diff) == 65_536
    end
  end
end
