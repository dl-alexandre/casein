defmodule Casein.Terminals.AgentProgressTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.AgentProgress

  setup do
    table = :"agent_progress_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:casein, :agent_progress_cache_table)
    Application.put_env(:casein, :agent_progress_cache_table, table)
    on_exit(fn -> Application.put_env(:casein, :agent_progress_cache_table, previous) end)
    AgentProgress.ensure_cache_table()
    :ok
  end

  defp base_opts(overrides) do
    Keyword.merge(
      [
        session: "casein_ws_main",
        pane_id: "%1",
        stall_after_ms: 1_000,
        worktree_path: "/tmp/wt",
        screen_reader: fn _, _ -> {:ok, "frozen timer 16.5s context 54.9K (11%) $0.11"} end,
        git_reader: fn _ ->
          %{
            available?: true,
            git_dir: "/tmp/wt/.git",
            head_sha: "abc",
            commit_count: 0,
            status_fingerprint: "deadbeef",
            dirty_count: 0,
            rebase_or_merge?: false,
            detached?: false
          }
        end
      ],
      overrides
    )
  end

  test "first sample is unknown/warming — not quiet and not stalled" do
    obs =
      AgentProgress.observe(
        base_opts(
          now_ms: 1_000,
          process: %{state: :active, cpu_jiffies: 10, cpu_jiffies_delta: nil}
        )
      )

    assert obs.state == :unknown
    assert obs.reason == :warming
    refute obs.state == :running_but_not_progressing
  end

  test "CPU advancing with frozen screen+worktree+context+spend is running_but_not_progressing" do
    # Incident shape: process burns CPU for a long wall time while every agent
    # progress axis is flat (frozen timer, stuck context %, stuck spend, 0 commits).
    frozen_screen = "build 16.5s  context 54.9K (11%)  spend $0.11"

    frozen_git = %{
      available?: true,
      git_dir: "/tmp/wt/.git",
      head_sha: "abc",
      commit_count: 0,
      status_fingerprint: "same",
      dirty_count: 0,
      rebase_or_merge?: false,
      detached?: false
    }

    opts = fn now, cpu, delta ->
      base_opts(
        now_ms: now,
        process: %{state: :active, cpu_jiffies: cpu, cpu_jiffies_delta: delta},
        screen_reader: fn _, _ -> {:ok, frozen_screen} end,
        git_reader: fn _ -> frozen_git end,
        stall_after_ms: 1_000
      )
    end

    _ = AgentProgress.observe(opts.(1_000, 100, nil))

    # Second sample soon — still settling
    mid = AgentProgress.observe(opts.(1_500, 250, 150))
    assert mid.state == :unknown
    assert mid.reason == :settling

    # Past stall_after with still-flat axes
    stalled = AgentProgress.observe(opts.(3_000, 400, 150))
    assert stalled.state == :running_but_not_progressing
    assert stalled.reason == :cpu_active_axes_stalled
    assert stalled.stalled_axis_count >= 2
    assert stalled.advanced_axis_count == 0
    # process_cpu axis may show advanced; it must not alone flip to progressing
    assert stalled.axes.process_cpu.verdict == :advanced
  end

  test "changing screen is positive progress even with quiet CPU" do
    git = %{
      available?: true,
      git_dir: "/tmp/wt/.git",
      head_sha: "abc",
      commit_count: 1,
      status_fingerprint: "x",
      dirty_count: 0,
      rebase_or_merge?: false,
      detached?: false
    }

    _ =
      AgentProgress.observe(
        base_opts(
          now_ms: 1_000,
          process: %{state: :quiet, cpu_jiffies: 10, cpu_jiffies_delta: 0},
          screen_reader: fn _, _ -> {:ok, "frame-a"} end,
          git_reader: fn _ -> git end
        )
      )

    obs =
      AgentProgress.observe(
        base_opts(
          now_ms: 3_000,
          process: %{state: :quiet, cpu_jiffies: 10, cpu_jiffies_delta: 0},
          screen_reader: fn _, _ -> {:ok, "frame-b mid-rebase output"} end,
          git_reader: fn _ -> git end
        )
      )

    assert obs.state == :progressing
    assert obs.reason == :screen_advanced
  end

  test "mid-rebase is in_flight progress — detached HEAD is not broken" do
    rebase_git = %{
      available?: true,
      git_dir: "/tmp/real-git-dir",
      head_sha: "def",
      commit_count: 3,
      status_fingerprint: "staged",
      dirty_count: 4,
      rebase_or_merge?: true,
      detached?: true
    }

    _ =
      AgentProgress.observe(
        base_opts(
          now_ms: 1_000,
          process: %{state: :active, cpu_jiffies: 10, cpu_jiffies_delta: nil},
          git_reader: fn _ -> rebase_git end,
          screen_reader: fn _, _ -> {:ok, "Rebasing (3/7)"} end
        )
      )

    # Even first sample can be progressing when rebase markers are present.
    first =
      AgentProgress.observe(
        base_opts(
          now_ms: 1_000,
          cache: false,
          process: %{state: :active, cpu_jiffies: 10, cpu_jiffies_delta: nil},
          git_reader: fn _ -> rebase_git end,
          screen_reader: fn _, _ -> {:ok, "Rebasing (3/7)"} end
        )
      )

    assert first.state == :progressing
    assert first.reason == :rebase_or_merge
    assert first.axes.worktree.verdict == :in_flight
    assert first.axes.worktree.value.detached? == true
  end

  test "worktree commit advance is progressing" do
    git1 = %{
      available?: true,
      git_dir: "/tmp/wt/.git",
      head_sha: "aaa",
      commit_count: 1,
      status_fingerprint: "s1",
      dirty_count: 0,
      rebase_or_merge?: false,
      detached?: false
    }

    git2 = %{git1 | head_sha: "bbb", commit_count: 2}

    _ =
      AgentProgress.observe(
        base_opts(
          now_ms: 1_000,
          process: %{state: :active, cpu_jiffies: 1, cpu_jiffies_delta: nil},
          git_reader: fn _ -> git1 end,
          screen_reader: fn _, _ -> {:ok, "same"} end
        )
      )

    obs =
      AgentProgress.observe(
        base_opts(
          now_ms: 5_000,
          process: %{state: :active, cpu_jiffies: 2, cpu_jiffies_delta: 1},
          git_reader: fn _ -> git2 end,
          screen_reader: fn _, _ -> {:ok, "same"} end
        )
      )

    assert obs.state == :progressing
    assert obs.reason == :worktree_advanced
  end

  test "context and spend parsers read TUI scrapes" do
    text = "opencode  build 16.5s\ncontext 54.9K (11%)  $0.11\n"

    _ =
      AgentProgress.observe(
        base_opts(
          now_ms: 1,
          process: %{state: :active, cpu_jiffies: 1, cpu_jiffies_delta: nil},
          screen_reader: fn _, _ -> {:ok, text} end
        )
      )

    # Bump context + spend on second sample
    text2 = "opencode  build 40.0s\ncontext 60.0K (12%)  $0.25\n"

    obs =
      AgentProgress.observe(
        base_opts(
          now_ms: 5_000,
          process: %{state: :active, cpu_jiffies: 50, cpu_jiffies_delta: 49},
          screen_reader: fn _, _ -> {:ok, text2} end
        )
      )

    assert obs.state == :progressing
    assert obs.axes.context.verdict == :advanced
    assert obs.axes.spend.verdict == :advanced
    assert obs.axes.context.value == 60_000
  end

  test "to_json stringifies state and axes" do
    obs =
      AgentProgress.observe(
        base_opts(
          now_ms: 1,
          process: %{state: :unknown, cpu_jiffies: nil, cpu_jiffies_delta: nil}
        )
      )

    json = AgentProgress.to_json(obs)
    assert json.state == "unknown"
    assert is_map(json.axes)
  end

  test "git_dir resolution path is used for rebase markers (linked worktree trap)" do
    # Prove we never look at worktree/.git/rebase-* as a directory listing of a file.
    # The reader returns git_dir pointing at the real common dir with rebase-merge.
    tmp = Path.join(System.tmp_dir!(), "ap-rebase-#{System.unique_integer([:positive])}")
    git_dir = Path.join(tmp, "real.git")
    File.mkdir_p!(Path.join(git_dir, "rebase-merge"))
    on_exit(fn -> File.rm_rf(tmp) end)

    # Default reader would shell out; inject facts that only appear when git-dir
    # was resolved (rebase_or_merge? true with detached).
    obs =
      AgentProgress.observe(
        base_opts(
          now_ms: 1,
          cache: false,
          process: %{state: :active, cpu_jiffies: 1, cpu_jiffies_delta: nil},
          git_reader: fn _ ->
            %{
              available?: true,
              git_dir: git_dir,
              head_sha: "detached",
              commit_count: 5,
              status_fingerprint: "staged-files",
              dirty_count: 2,
              rebase_or_merge?: File.exists?(Path.join(git_dir, "rebase-merge")),
              detached?: true
            }
          end
        )
      )

    assert obs.state == :progressing
    assert obs.axes.worktree.value.rebase_or_merge? == true
  end
end
