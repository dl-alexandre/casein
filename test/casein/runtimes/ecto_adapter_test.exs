defmodule Casein.Runtimes.EctoAdapterTest do
  use Casein.DataCase, async: false

  alias Casein.Repo
  alias Casein.Runtimes
  alias Casein.Runtimes.RuntimeRow
  alias Casein.Test.RuntimeSeed

  setup do
    Casein.Runtimes.EctoAdapter.clear()

    prev_runtime = Application.get_env(:casein, :runtimes_adapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.EctoAdapter)

    on_exit(fn ->
      Casein.Runtimes.EctoAdapter.clear()

      if prev_runtime,
        do: Application.put_env(:casein, :runtimes_adapter, prev_runtime),
        else: Application.delete_env(:casein, :runtimes_adapter)
    end)

    :ok
  end

  test "runtime projections and lifecycle events persist through Ecto" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-ecto-runtime",
        runtime_id: "rt-ecto",
        host_id: "ecto-host",
        status: "provisioned",
        repo: "onebackend-v3",
        branch: "main",
        worktree_path: "/tmp/ws-ecto-runtime/.casein/runtimes/rt-ecto"
      )

    assert runtime.status == "provisioned"

    assert {:ok, fetched} = Runtimes.get_runtime(runtime.id)
    assert fetched.repo == "onebackend-v3"
    assert fetched.status == "provisioned"

    events = Runtimes.events_for(runtime.id)
    assert Enum.map(events, & &1.event) == ~w(runtime_requested)
    assert {:ok, "requested"} = Runtimes.project_lifecycle(events)
  end

  describe "list_agent_worktree_runtimes/1" do
    test "returns the newest row per worktree path and skips retired rows" do
      ws = "ws-worktree-dedupe"
      path = "/tmp/#{ws}/agent-a"

      seed_agent_worktree(ws, "rt-old", path, created_at: minutes_ago(30))
      seed_agent_worktree(ws, "rt-new", path, created_at: minutes_ago(1))
      seed_agent_worktree(ws, "rt-gone", "/tmp/#{ws}/agent-b", status: "cleaned")
      seed_agent_worktree(ws, "rt-live", "/tmp/#{ws}/agent-c")

      ids = ws |> Runtimes.list_agent_worktree_runtimes() |> Enum.map(& &1.id)

      assert Enum.sort(ids) == ["rt-live", "rt-new"]
    end

    # Regression: the worktree list used to page the generic oldest-first,
    # 500-row `list_runtimes/1`. Once a workspace's history filled that window,
    # every worktree created afterwards became invisible — to the session picker
    # and to `observe_worktree/2`, which then inserted a duplicate row on every
    # reconcile instead of updating the one it could no longer see.
    test "finds worktrees created after the generic list cap is exhausted" do
      ws = "ws-worktree-cap"
      insert_filler_runtimes(ws, 520)

      seed_agent_worktree(ws, "rt-recent", "/tmp/#{ws}/agent-recent")

      assert Runtimes.list_runtimes(%{"workspace_id" => ws})
             |> Enum.all?(&(&1.id != "rt-recent")),
             "precondition: the capped generic list must not reach the newest row"

      assert [%{id: "rt-recent"}] = Runtimes.list_agent_worktree_runtimes(ws)
      assert [%{runtime_id: "rt-recent"}] = Runtimes.list_agent_worktrees(ws)
    end
  end

  test "count_runtimes_by_workspace_ids/1 aggregates without loading rows" do
    seed_agent_worktree("ws-count-a", "rt-a1", "/tmp/a1", status: "provisioned")
    seed_agent_worktree("ws-count-a", "rt-a2", "/tmp/a2", status: "cleaned")
    seed_agent_worktree("ws-count-b", "rt-b1", "/tmp/b1", status: "active")

    counts =
      Runtimes.count_runtimes_by_workspace_ids(["ws-count-a", "ws-count-b", "ws-count-none"])

    assert counts["ws-count-a"] == %{total: 2, active: 1}
    assert counts["ws-count-b"] == %{total: 1, active: 1}
    refute Map.has_key?(counts, "ws-count-none")
  end

  defp seed_agent_worktree(workspace_id, id, path, attrs \\ []) do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime(
        workspace_id,
        attrs
        |> Map.new()
        |> Map.merge(%{
          id: id,
          worktree_path: path,
          isolation_mode: "worktree",
          status: Keyword.get(attrs, :status, "provisioned"),
          metadata: %{"kind" => "agent_worktree"}
        })
      )

    runtime
  end

  # Bypasses the adapter deliberately: this is bulk fixture volume, not behaviour
  # under test, and 520 lifecycle transactions would dominate the test's runtime.
  defp insert_filler_runtimes(workspace_id, count) do
    now = DateTime.utc_now()

    rows =
      for index <- 1..count do
        at = DateTime.add(now, -(count - index) - 3600, :second)

        %{
          id: "rt-filler-#{index}",
          workspace_id: workspace_id,
          host_id: "local",
          isolation_mode: "worktree",
          status: "cleaned",
          capabilities: [],
          tools: [],
          concurrency_limit: 1,
          active_assignments: 0,
          created_at: at,
          heartbeat_at: at,
          metadata: %{"kind" => "agent_worktree"},
          inserted_at: at,
          updated_at: at
        }
      end

    Repo.insert_all(RuntimeRow, rows)
  end

  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
end
