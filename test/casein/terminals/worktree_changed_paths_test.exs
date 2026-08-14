defmodule Casein.Terminals.WorktreeChangedPathsTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.WorktreeChangedPaths

  @now ~U[2026-08-14 12:00:00Z]
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
    WorktreeChangedPaths.project(
      topo,
      Keyword.merge(
        [workspace_id: @ws, session: @session, pane: "%42", now: @now],
        opts
      )
    )
  end

  describe "project/2 identity and porcelain" do
    test "joins pane identity with parsed dirty paths" do
      status = fn path ->
        assert path == "/tmp/wt-worker"
        {:ok, " M lib/foo.ex\0?? new.txt\0"}
      end

      payload = project(topology([pane("%42")]), status: status)

      assert payload.found? == true
      assert payload.pane_id == "%42"
      assert payload.window_id == "@9"
      assert payload.worktree_path == "/tmp/wt-worker"
      assert payload.status_state == "ok"
      assert payload.count == 2
      assert payload.truncated? == false

      assert payload.changed_paths == [
               %{xy: " M", path: "lib/foo.ex"},
               %{xy: "??", path: "new.txt"}
             ]

      assert payload.note =~ "M4.3"
    end

    test "rename carries orig_path from the next -z token" do
      status = fn _ -> {:ok, "R  lib/old.ex\0lib/new.ex\0"} end
      payload = project(topology([pane("%42")]), status: status)

      assert payload.changed_paths == [
               %{xy: "R ", path: "lib/new.ex", orig_path: "lib/old.ex"}
             ]
    end

    test "successful empty porcelain is an honest empty list" do
      payload = project(topology([pane("%42")]), status: fn _ -> {:ok, ""} end)

      assert payload.status_state == "ok"
      assert payload.changed_paths == []
      assert payload.count == 0
    end

    test "pane not found omits changed_paths" do
      payload = project(topology([]), pane: "%99")

      assert payload.found? == false
      assert payload.status_state == "unknown"
      assert payload.unknown_reason == "pane_not_found"
      refute Map.has_key?(payload, :changed_paths)
    end
  end

  # Constraints in the artifact (not only the brief). If a later slice
  # "helpfully" treats status failure as an empty change list, these fail first.
  describe "contract: unknown never looks like a clean tree" do
    test "status error never emits changed_paths: []" do
      payload = project(topology([pane("%42")]), status: fn _ -> :error end)

      assert payload.status_state == "unknown"
      assert payload.unknown_reason == "status_failed"
      refute Map.has_key?(payload, :changed_paths)
      refute Map.has_key?(payload, :count)
      refute Map.has_key?(payload, :worktree_status)
    end

    test "missing worktree is unknown, not an empty change list" do
      payload = project(topology([pane("%42", worktree_path: nil)]))

      assert payload.status_state == "unknown"
      assert payload.unknown_reason == "no_worktree"
      refute Map.has_key?(payload, :changed_paths)
    end

    test "payload does not invent path-contract / diff / graph fields" do
      payload =
        project(topology([pane("%42")]), status: fn _ -> {:ok, " M a.ex\0"} end)

      forbid = [
        :orchestration_id,
        :task_id,
        :attempt_id,
        :contract_version,
        :path_contract,
        :forbidden_paths,
        :diff,
        :patch,
        :worktree_status
      ]

      for key <- forbid do
        refute Map.has_key?(payload, key),
               "payload must not carry #{key} (out of scope for worktree_changed_paths M4.3)"
      end
    end

    test "caps the list and flags truncated? without dropping status_state ok" do
      body =
        1..205
        |> Enum.map_join("\0", &" M file#{&1}.ex")
        |> Kernel.<>("\0")

      payload = project(topology([pane("%42")]), status: fn _ -> {:ok, body} end)

      assert payload.status_state == "ok"
      assert payload.count == 200
      assert payload.truncated? == true
      assert length(payload.changed_paths) == 200
    end
  end
end
