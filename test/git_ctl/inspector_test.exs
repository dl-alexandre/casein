defmodule GitCtl.InspectorTest do
  use ExUnit.Case, async: true

  import DevIDE.Test.GitRepoCase

  alias GitCtl.Inspector

  setup context do
    context = setup_git_repo(context)
    on_exit(fn -> File.rm_rf!(context.tmp) end)
    context
  end

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

  test "returns error for non-git directories and missing paths" do
    tmp = Path.join(tmp_root(), "devide-non-git-#{System.unique_integer([:positive])}")
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

  test "infers agent from path patterns" do
    assert Inspector.infer_agent("/home/dev/.local/share/opencode/auth") == "opencode"
    assert Inspector.infer_agent("/home/dev/.claude/worktrees/fix") == "claude"
    assert Inspector.infer_agent("/tmp/grok-build") == "grok"
    assert Inspector.infer_agent("/tmp/codex-worktree") == "codex"
    assert Inspector.infer_agent("/home/dev/project") == nil
    assert Inspector.infer_agent(123) == nil
  end
end
