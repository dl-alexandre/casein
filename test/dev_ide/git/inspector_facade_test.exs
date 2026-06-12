defmodule DevIDE.Git.InspectorFacadeTest do
  use ExUnit.Case, async: true

  import DevIDE.Test.GitRepoCase

  alias DevIDE.Git.Inspector

  setup context do
    context = setup_git_repo(context)
    on_exit(fn -> File.rm_rf!(context.tmp) end)
    context
  end

  test "inspect_cwd returns a DevIDE.Git.Inspector struct", %{main: main} do
    assert {:ok, %Inspector{toplevel: ^main, branch: "main"}} = Inspector.inspect_cwd(main)
  end

  test "cache_table delegates to GitCtl.Cache" do
    assert Inspector.cache_table() == GitCtl.Cache.table()
  end
end
