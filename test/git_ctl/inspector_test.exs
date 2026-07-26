defmodule GitCtl.InspectorTest do
  use Casein.TestCase, async: false

  import Casein.Test.GitRepoCase

  alias GitCtl.Inspector

  setup :setup_git_repo

  test "inspects normal main checkout", %{main: main} do
    assert {:ok, info} = Inspector.inspect_cwd(main)
    assert info.toplevel == main
    assert info.worktree? == false
    assert info.detached? == false
    assert info.branch == "main"
    assert info.agent == nil
    assert String.length(info.head_sha) > 0
  end

  test "inspects linked worktree", %{worktree: worktree} do
    assert {:ok, info} = Inspector.inspect_cwd(worktree)
    assert info.toplevel == worktree
    assert info.worktree? == true
    assert info.branch == "feature-test"
  end

  test "inspects detached HEAD worktree", %{detached_worktree: detached} do
    assert {:ok, info} = Inspector.inspect_cwd(detached)
    assert info.worktree? == true
    assert info.detached? == true
    assert String.match?(info.branch, ~r/^[0-9a-f]{4,}$/)
  end

  test "reports nil upstream/ahead/behind when no upstream is configured", %{main: main} do
    assert {:ok, info} = Inspector.inspect_cwd(main)
    assert info.upstream == nil
    assert info.ahead == nil
    assert info.behind == nil
  end

  test "reports nil upstream/ahead/behind on a detached HEAD", %{detached_worktree: detached} do
    assert {:ok, info} = Inspector.inspect_cwd(detached)
    assert info.detached? == true
    assert info.upstream == nil
    assert info.ahead == nil
    assert info.behind == nil
  end

  test "counts ahead/behind against the configured upstream", %{tmp: tmp, main: main} do
    remote = Path.join(tmp, "remote.git")
    git!(main, ["init", "--bare", remote])
    git!(main, ["remote", "add", "origin", remote])
    git!(main, ["push", "-q", "-u", "origin", "main"])

    # One commit the upstream has that HEAD does not (behind: 1), then two
    # local commits the upstream never received (ahead: 2) — asymmetric on
    # purpose so a swapped ahead/behind cannot pass.
    File.write!(Path.join(main, "pushed.txt"), "pushed\n")
    git!(main, ["add", "pushed.txt"])
    git!(main, ["commit", "-q", "-m", "pushed"])
    git!(main, ["push", "-q", "origin", "main"])
    git!(main, ["reset", "-q", "--hard", "HEAD~1"])

    for n <- 1..2 do
      File.write!(Path.join(main, "local-#{n}.txt"), "local #{n}\n")
      git!(main, ["add", "local-#{n}.txt"])
      git!(main, ["commit", "-q", "-m", "local only #{n}"])
    end

    assert {:ok, info} = Inspector.inspect_cwd(main)
    assert info.upstream == "origin/main"
    assert info.ahead == 2
    assert info.behind == 1
  end

  test "returns error for non-git directories and missing paths" do
    tmp = Path.join(tmp_root(), "casein-non-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert Inspector.inspect_cwd(tmp) == :error
    assert Inspector.inspect_cwd("/non/existent/path") == :error
    assert Inspector.inspect_cwd(123) == :error
  end

  test "caches results per cwd within the TTL", %{main: main} do
    table = :"git_ctl_inspector_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :public, :set])

    prev_table = Application.get_env(:git_ctl, :cache_table)
    prev_ttl = Application.get_env(:git_ctl, :cache_ttl_ms)
    Application.put_env(:git_ctl, :cache_table, table)
    Application.put_env(:git_ctl, :cache_ttl_ms, 60_000)

    on_exit(fn ->
      if prev_table,
        do: Application.put_env(:git_ctl, :cache_table, prev_table),
        else: Application.delete_env(:git_ctl, :cache_table)

      if prev_ttl,
        do: Application.put_env(:git_ctl, :cache_ttl_ms, prev_ttl),
        else: Application.delete_env(:git_ctl, :cache_ttl_ms)

      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    assert {:ok, info} = Inspector.inspect_cwd(main)
    assert info.branch == "main"

    git!(main, ["checkout", "-q", "-b", "cache-probe"])

    assert {:ok, cached} = Inspector.inspect_cwd(main)
    assert cached.branch == "main"

    Application.put_env(:git_ctl, :cache_ttl_ms, 0)
    assert {:ok, fresh} = Inspector.inspect_cwd(main)
    assert fresh.branch == "cache-probe"
  end

  test "applies host-configured agent inference", %{worktree: worktree} do
    prev = Application.get_env(:git_ctl, :agent_inference)

    Application.put_env(:git_ctl, :agent_inference, fn path ->
      if path == worktree, do: "test-agent"
    end)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:git_ctl, :agent_inference, prev),
        else: Application.delete_env(:git_ctl, :agent_inference)
    end)

    assert {:ok, info} = Inspector.inspect_cwd(worktree)
    assert info.agent == "test-agent"
  end
end
