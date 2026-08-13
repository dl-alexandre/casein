defmodule Casein.Terminals.WorktreeStatusTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.WorktreeStatus

  @now ~U[2026-08-13 15:00:00Z]
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
    WorktreeStatus.project(
      topo,
      Keyword.merge(
        [workspace_id: @ws, session: @session, pane: "%42", now: @now],
        opts
      )
    )
  end

  describe "project/2 identity" do
    test "joins pane identity and inspector facts" do
      inspect = fn path ->
        assert path == "/tmp/wt-worker"

        {:ok,
         %{
           branch: "agent/opencode/demo",
           head_sha: "abc1234",
           upstream: "origin/master",
           ahead: 2,
           behind: 0,
           detached?: false
         }}
      end

      payload = project(topology([pane("%42")]), inspect: inspect)

      assert payload.found? == true
      assert payload.pane_id == "%42"
      assert payload.window_id == "@9"
      assert payload.window_name == "worker-demo"
      assert payload.worktree_path == "/tmp/wt-worker"
      assert payload.git.inspect_state == "ok"
      assert payload.git.branch == "agent/opencode/demo"
      assert payload.git.head_sha == "abc1234"
      assert payload.git.upstream == "origin/master"
      assert payload.git.ahead == 2
      assert payload.git.behind == 0
      assert payload.git.commits_not_on_origin? == true
      assert payload.note =~ "M4.2"
    end

    test "pane not found is found? false with unknown git" do
      payload = project(topology([]), pane: "%99")

      assert payload.found? == false
      assert payload.git.inspect_state == "unknown"
      assert payload.git.unknown_reason == "pane_not_found"
      refute Map.has_key?(payload.git, :ahead)
    end
  end

  # Constraints in the artifact (not only the brief). If a later slice
  # "helpfully" treats inspect failure as clean / not-ahead, these fail first.
  describe "contract: unknown is never clean or not-ahead" do
    test "inspect error never emits ahead: 0 or commits_not_on_origin?: false" do
      payload = project(topology([pane("%42")]), inspect: fn _ -> :error end)

      assert payload.found? == true
      assert payload.git.inspect_state == "unknown"
      assert payload.git.unknown_reason == "inspect_failed"
      refute Map.has_key?(payload.git, :ahead)
      refute Map.has_key?(payload.git, :behind)
      refute Map.has_key?(payload.git, :commits_not_on_origin?)
      refute Map.has_key?(payload.git, :worktree_status)
      refute Map.has_key?(payload, :worktree_status)
    end

    test "missing worktree is unknown, not clean" do
      payload = project(topology([pane("%42", worktree_path: nil)]))

      assert payload.git.inspect_state == "unknown"
      assert payload.git.unknown_reason == "no_worktree"
      refute Map.has_key?(payload.git, :ahead)
      refute Map.has_key?(payload.git, :commits_not_on_origin?)
    end

    test "ahead nil (no upstream) omits commits_not_on_origin? — not false-unpushed" do
      inspect = fn _ ->
        {:ok,
         %{
           branch: "agent/opencode/demo",
           head_sha: "def5678",
           upstream: nil,
           ahead: nil,
           behind: nil,
           detached?: false
         }}
      end

      payload = project(topology([pane("%42")]), inspect: inspect)

      assert payload.git.inspect_state == "ok"
      assert payload.git.branch == "agent/opencode/demo"
      refute Map.has_key?(payload.git, :ahead)
      refute Map.has_key?(payload.git, :commits_not_on_origin?)
    end

    test "ahead 0 is a real count, not unknown" do
      inspect = fn _ ->
        {:ok,
         %{
           branch: "agent/opencode/demo",
           head_sha: "aaa1111",
           upstream: "origin/master",
           ahead: 0,
           behind: 1,
           detached?: false
         }}
      end

      payload = project(topology([pane("%42")]), inspect: inspect)

      assert payload.git.ahead == 0
      assert payload.git.behind == 1
      assert payload.git.commits_not_on_origin? == false
    end

    test "payload does not invent durable-graph / dirty-clean fields" do
      inspect = fn _ ->
        {:ok, %{branch: "x", head_sha: "y", ahead: 0, behind: 0, detached?: false}}
      end

      payload = project(topology([pane("%42")]), inspect: inspect)

      forbid = [
        :orchestration_id,
        :task_id,
        :attempt_id,
        :contract_version,
        :path_contract,
        :verifier_run_id,
        :changed_paths,
        :worktree_status
      ]

      for key <- forbid do
        refute Map.has_key?(payload, key),
               "payload must not carry #{key} (out of scope for worktree_status M4.2)"

        refute Map.has_key?(payload.git, key),
               "git must not carry #{key} (out of scope for worktree_status M4.2)"
      end
    end
  end
end
