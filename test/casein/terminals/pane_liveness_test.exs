defmodule Casein.Terminals.PaneLivenessTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.PaneLiveness

  setup do
    root = Path.join(System.tmp_dir!(), "pane-liveness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  describe "worktree resolution" do
    test "resolves a pane's worktree from its tmux cwd", %{root: root} do
      worktree = git_repo!(root, "wt")
      nested = Path.join(worktree, "lib/deep")
      File.mkdir_p!(nested)

      # A pane sitting deep inside the tree still resolves to its root.
      assert PaneLiveness.pane_worktree(pane("%1", nested)) == worktree
    end

    test "a pane outside any repo has no worktree", %{root: root} do
      plain = Path.join(root, "not-a-repo")
      File.mkdir_p!(plain)

      assert PaneLiveness.pane_worktree(pane("%1", plain)) == nil
    end

    test "a pane with no cwd has no worktree" do
      assert PaneLiveness.pane_worktree(%{id: "%1"}) == nil
      assert PaneLiveness.pane_worktree(pane("%1", "")) == nil
    end
  end

  describe "shared worktree detection" do
    test "flags panes sitting in one worktree, with the other pane ids", %{root: root} do
      shared = git_repo!(root, "shared")
      own = git_repo!(root, "own")

      topology = topology([pane("%1", shared), pane("%2", shared), pane("%3", own)])

      assert %{^shared => ids} = PaneLiveness.shared_worktrees(topology)
      assert Enum.sort(ids) == ["%1", "%2"]
      # A pane with its own worktree is never flagged.
      refute Map.has_key?(PaneLiveness.shared_worktrees(topology), own)
    end

    test "three windows in one worktree is the case that corrupts git state", %{root: root} do
      # The reported incident: windows 2, 3 and 4 all adopted one worktree, and
      # nothing surfaced it. Adoption is deliberate, so this warns rather than
      # refuses — but it must be visible.
      shared = git_repo!(root, "shared")

      enriched =
        PaneLiveness.enrich_topology(
          topology([pane("%2", shared), pane("%3", shared), pane("%4", shared)]),
          liveness: false
        )

      for p <- enriched.panes do
        assert p.worktree_path == shared
        assert length(p.worktree_shared_with) == 2
        refute p.id in p.worktree_shared_with
      end
    end

    test "several shells in one plain directory are not flagged", %{root: root} do
      plain = Path.join(root, "home")
      File.mkdir_p!(plain)

      assert PaneLiveness.shared_worktrees(topology([pane("%1", plain), pane("%2", plain)])) ==
               %{}
    end

    test "a solo pane carries a worktree but no sharing key", %{root: root} do
      worktree = git_repo!(root, "solo")

      enriched =
        PaneLiveness.enrich_topology(topology([pane("%1", worktree)]), liveness: false)

      assert [%{worktree_path: ^worktree} = p] = enriched.panes
      refute Map.has_key?(p, :worktree_shared_with)
    end
  end

  describe "liveness enrichment" do
    test "attaches an active verdict for a freshly written worktree", %{root: root} do
      worktree = git_repo!(root, "busy")
      File.write!(Path.join(worktree, "new.ex"), "x")

      enriched = PaneLiveness.enrich_topology(topology([pane("%1", worktree)]), [])

      assert [%{liveness: %{state: :active}}] = enriched.panes
    end

    test "attaches a quiet verdict for an untouched worktree", %{root: root} do
      worktree = git_repo!(root, "quiet")
      backdate!(Path.join(worktree, "seed.txt"), 7200)

      enriched = PaneLiveness.enrich_topology(topology([pane("%1", worktree)]), [])

      assert [%{liveness: %{state: :quiet, quiet_for_seconds: quiet_for}}] = enriched.panes
      assert quiet_for >= 7000
    end

    test "only agent-tagged panes are observed by default", %{root: root} do
      worktree = git_repo!(root, "mixed")
      File.write!(Path.join(worktree, "new.ex"), "x")

      shell = pane("%2", worktree, role: "shell")
      enriched = PaneLiveness.enrich_topology(topology([shell]), [])

      # A plain shell's cwd is not an agent worktree; walking it is wasted work.
      assert [p] = enriched.panes
      refute Map.has_key?(p, :liveness)

      # ...but the caller can ask for it.
      opened = PaneLiveness.enrich_topology(topology([shell]), agent_panes_only: false)
      assert [%{liveness: %{state: :active}}] = opened.panes
    end

    test "liveness: false resolves worktrees without walking them", %{root: root} do
      worktree = git_repo!(root, "cheap")
      File.write!(Path.join(worktree, "new.ex"), "x")

      enriched = PaneLiveness.enrich_topology(topology([pane("%1", worktree)]), liveness: false)

      assert [p] = enriched.panes
      assert p.worktree_path == worktree
      refute Map.has_key?(p, :liveness)
    end
  end

  describe "observe_pane/2" do
    test "reports why an observation is missing rather than omitting it", %{root: root} do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)

      assert {:error, :no_worktree} = PaneLiveness.observe_pane(pane("%1", plain))
      assert {:error, :no_worktree} = PaneLiveness.observe_pane(%{id: "%1"})
    end

    test "returns the worktree and its liveness", %{root: root} do
      worktree = git_repo!(root, "observed")
      File.write!(Path.join(worktree, "new.ex"), "x")

      assert {:ok, ^worktree, liveness} =
               PaneLiveness.observe_pane(pane("%1", worktree), cache: false)

      assert liveness.state == :active
      assert liveness.commit_count == 1
      assert liveness.head_sha =~ ~r/^[0-9a-f]{40}$/
    end

    test "a vanished worktree is an error, never a quiet verdict", %{root: root} do
      worktree = git_repo!(root, "doomed")
      p = pane("%1", worktree)
      File.rm_rf!(worktree)

      # Reporting :quiet here would be a false stall — the check could not run.
      assert {:error, _reason} = PaneLiveness.observe_pane(p, cache: false)
    end
  end

  describe "cockpit cadence" do
    setup do
      PaneLiveness.ensure_cockpit_cache!()
      {:ok, session: "casein_test_#{System.unique_integer([:positive])}"}
    end

    test "cached/1 is empty before any refresh — absence, not quiet", %{session: session} do
      assert PaneLiveness.cached(session) == %{}
      assert PaneLiveness.cached(nil) == %{}
    end

    test "observe_panes stores liveness and worktree per pane", %{root: root, session: session} do
      worktree = git_repo!(root, "live")
      File.write!(Path.join(worktree, "new.ex"), "x")

      snapshot = PaneLiveness.observe_panes(session, [pane("%1", worktree)], cache: false)

      assert %{"%1" => %{liveness: liveness, worktree_path: ^worktree}} = snapshot
      assert liveness.state == :active
      # And it is readable from the render path without touching disk.
      assert PaneLiveness.cached(session) == snapshot
    end

    test "an unobservable pane keeps its reason instead of being dropped", %{
      root: root,
      session: session
    } do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)

      snapshot = PaneLiveness.observe_panes(session, [pane("%9", plain)], cache: false)

      # Omitting it would decay into "not observed" downstream, which says less
      # than the reason we already have.
      assert %{"%9" => %{liveness: %{state: :unknown, reason: :no_worktree}}} = snapshot
    end

    test "refresh_async holds off inside the TTL and skips an empty pane list", %{
      root: root,
      session: session
    } do
      worktree = git_repo!(root, "async")
      PaneLiveness.subscribe()

      assert :skip = PaneLiveness.refresh_async(session, [])
      assert :started = PaneLiveness.refresh_async(session, [pane("%1", worktree)])
      assert_receive {:pane_liveness, :refreshed, ^session}, 5_000

      assert %{"%1" => _} = PaneLiveness.cached(session)
      # A burst of topology assigns must not fan out into a burst of walks.
      assert :fresh = PaneLiveness.refresh_async(session, [pane("%1", worktree)])
    end
  end

  test "a topology without panes passes through untouched" do
    assert PaneLiveness.enrich_topology(%{windows: []}, []) == %{windows: []}
  end

  ## Helpers

  defp topology(panes), do: %{panes: panes, windows: []}

  defp pane(id, current_path, opts \\ []) do
    %{
      id: id,
      current_path: current_path,
      role: Keyword.get(opts, :role, "agent")
    }
  end

  defp git_repo!(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    git!(["init", "--quiet", "--initial-branch=main", path])
    git!(["-C", path, "config", "user.email", "t@t"])
    git!(["-C", path, "config", "user.name", "t"])
    File.write!(Path.join(path, "seed.txt"), "x")
    git!(["-C", path, "add", "seed.txt"])
    git!(["-C", path, "commit", "--quiet", "-m", "seed"])
    path
  end

  defp backdate!(path, seconds_ago) do
    stamp =
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> Calendar.strftime("%Y%m%d%H%M.%S")

    {_, 0} = System.cmd("touch", ["-t", stamp, path])
    :ok
  end

  defp git!(args) do
    {_, 0} = System.cmd("git", args, stderr_to_stdout: true, env: git_env())
    :ok
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@t"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@t"}
    ]
  end
end
