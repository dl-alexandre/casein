defmodule Casein.Git.InspectorFacadeTest do
  use Casein.TestCase, async: true

  import Casein.Test.GitRepoCase

  alias Casein.Git.Inspector

  setup :setup_git_repo

  test "inspect_cwd returns a Casein.Git.Inspector struct", %{main: main} do
    assert {:ok, %Inspector{toplevel: ^main, branch: "main"}} = Inspector.inspect_cwd(main)
  end

  test "cache_table delegates to GitCtl.Cache" do
    assert Inspector.cache_table() == GitCtl.Cache.table()
  end

  test "infer_agent returns nil for non-binary input" do
    assert Inspector.infer_agent(nil) == nil
    assert Inspector.infer_agent(123) == nil
  end

  test "struct fields mirror GitCtl.Inspector" do
    assert Inspector.__struct__() |> Map.keys() |> Enum.sort() ==
             GitCtl.Inspector.__struct__() |> Map.keys() |> Enum.sort()
  end
end
