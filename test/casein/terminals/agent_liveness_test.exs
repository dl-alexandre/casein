defmodule Casein.Terminals.AgentLivenessTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.AgentLiveness

  setup do
    root = Path.join(System.tmp_dir!(), "liveness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "absence vs. failure" do
    # The whole point of the module: a scan that could not run must not read as
    # a confident "nothing happened". These two cases were the same empty result
    # in the shell one-liners this replaces.
    test "an unscannable worktree is an error, not a quiet one" do
      assert {:error, :enoent} = AgentLiveness.observe("/definitely/not/here", cache: false)
    end

    test "a file where a worktree should be is an error, not a quiet one", %{root: root} do
      file = Path.join(root, "regular-file")
      File.write!(file, "x")

      assert {:error, :not_a_directory} = AgentLiveness.observe(file, cache: false)
    end

    test "a missing path is an error rather than a crash" do
      assert {:error, :no_path} = AgentLiveness.observe(nil)
      assert {:error, :no_path} = AgentLiveness.observe("")
    end

    test "an empty worktree scans successfully with no writes", %{root: root} do
      assert {:ok, observation} = AgentLiveness.observe(root, cache: false, git: false)

      # Distinguishable from {:error, _}: the scan ran, there is just nothing here.
      assert observation.last_write_at == nil
      assert observation.quiet_for_seconds == nil
      assert observation.files_scanned == 0
    end
  end

  describe "observing writes" do
    test "reports the newest write in the tree", %{root: root} do
      File.mkdir_p!(Path.join(root, "lib/deep/nested"))
      File.write!(Path.join(root, "lib/deep/nested/new.ex"), "x")

      assert {:ok, observation} = AgentLiveness.observe(root, cache: false, git: false)

      assert %DateTime{} = observation.last_write_at
      assert observation.files_scanned == 1
      assert observation.quiet_for_seconds <= 5
    end

    test "an old write yields a large quiet_for_seconds", %{root: root} do
      path = Path.join(root, "stale.ex")
      File.write!(path, "x")
      backdate!(path, 3600)

      assert {:ok, observation} = AgentLiveness.observe(root, cache: false, git: false)

      assert observation.quiet_for_seconds >= 3500
      assert AgentLiveness.classify(observation, []) == :quiet
    end

    test "build and dependency dirs never count as agent activity", %{root: root} do
      # A compile touches _build; a `git status` from a shell prompt touches
      # .git. Neither is the agent thinking, and counting them would make an
      # abandoned worktree look permanently alive.
      for dir <- ~w(_build deps node_modules .git) do
        File.mkdir_p!(Path.join(root, dir))
        File.write!(Path.join([root, dir, "fresh.txt"]), "x")
      end

      assert {:ok, observation} = AgentLiveness.observe(root, cache: false, git: false)

      assert observation.files_scanned == 0
      assert observation.last_write_at == nil
    end

    test "symlinks are not followed out of the worktree", %{root: root} do
      other = Path.join(System.tmp_dir!(), "other-#{System.unique_integer([:positive])}")
      File.mkdir_p!(other)
      File.write!(Path.join(other, "someone-elses-work.ex"), "x")
      on_exit(fn -> File.rm_rf(other) end)

      File.ln_s!(other, Path.join(root, "link"))

      assert {:ok, observation} = AgentLiveness.observe(root, cache: false, git: false)

      # Following the link would attribute another agent's writes to this one.
      assert observation.files_scanned == 0
    end
  end

  describe "classify/2" do
    test "recent writes are active, old ones are quiet", %{root: root} do
      File.write!(Path.join(root, "a.ex"), "x")
      {:ok, fresh} = AgentLiveness.observe(root, cache: false, git: false)

      assert AgentLiveness.classify(fresh, []) == :active
      # A window narrower than the file's age flips the verdict.
      assert AgentLiveness.classify(%{fresh | quiet_for_seconds: 600}, []) == :quiet

      assert AgentLiveness.classify(%{fresh | quiet_for_seconds: 600}, window_seconds: 900) ==
               :active
    end

    test "an empty worktree is quiet, not active", %{root: root} do
      {:ok, observation} = AgentLiveness.observe(root, cache: false, git: false)

      assert AgentLiveness.classify(observation, []) == :quiet
    end
  end

  describe "progressed?/2" do
    test "a new commit counts as progress even with no new writes" do
      earlier = observation(commit_count: 4)
      later = observation(commit_count: 5)

      assert AgentLiveness.progressed?(earlier, later)
    end

    test "a newer write counts as progress" do
      earlier = observation(last_write_at: ~U[2026-08-07 10:00:00Z])
      later = observation(last_write_at: ~U[2026-08-07 10:05:00Z])

      assert AgentLiveness.progressed?(earlier, later)
    end

    test "an unchanged worktree is not progress" do
      same = observation(commit_count: 4, last_write_at: ~U[2026-08-07 10:00:00Z])

      refute AgentLiveness.progressed?(same, same)
    end

    test "a missing observation is never progress" do
      refute AgentLiveness.progressed?(nil, observation(commit_count: 5))
      refute AgentLiveness.progressed?(observation(commit_count: 5), nil)
    end
  end

  describe "git facts" do
    test "reports HEAD and commit count for a real worktree", %{root: root} do
      git!(["init", "--quiet", "--initial-branch=main", root])
      git!(["-C", root, "config", "user.email", "t@t"])
      git!(["-C", root, "config", "user.name", "t"])
      File.write!(Path.join(root, "a.ex"), "x")
      git!(["-C", root, "add", "a.ex"])
      git!(["-C", root, "commit", "--quiet", "-m", "one"])

      assert {:ok, observation} = AgentLiveness.observe(root, cache: false)

      assert observation.commit_count == 1
      assert observation.head_sha =~ ~r/^[0-9a-f]{40}$/
    end

    test "a non-git directory still scans, with nil git facts", %{root: root} do
      File.write!(Path.join(root, "a.ex"), "x")

      assert {:ok, observation} = AgentLiveness.observe(root, cache: false)

      assert observation.head_sha == nil
      assert observation.commit_count == nil
      # The mtime half is unaffected by git being unavailable.
      assert %DateTime{} = observation.last_write_at
    end
  end

  describe "caching" do
    test "a cached observation still ages", %{root: root} do
      File.write!(Path.join(root, "a.ex"), "x")

      {:ok, first} = AgentLiveness.observe(root, git: false)
      later = DateTime.add(first.observed_at, 120, :second)
      {:ok, second} = AgentLiveness.observe(root, git: false, now: later)

      # Same scan, but the staleness arithmetic must be recomputed — otherwise a
      # cached entry reports a worktree as freshly-active forever.
      assert second.last_write_at == first.last_write_at
      assert second.quiet_for_seconds >= first.quiet_for_seconds + 119
    end
  end

  defp observation(overrides) do
    base = %{
      worktree_path: "/tmp/x",
      observed_at: ~U[2026-08-07 10:00:00Z],
      last_write_at: nil,
      quiet_for_seconds: nil,
      files_scanned: 0,
      truncated?: false,
      head_sha: nil,
      commit_count: nil
    }

    Enum.into(overrides, base)
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
