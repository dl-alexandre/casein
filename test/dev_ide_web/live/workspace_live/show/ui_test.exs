defmodule DevIdeWeb.WorkspaceLive.Show.UITest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.WorkspaceLive.Show.UI

  describe "workspace_short_name/1" do
    test "drops the redundant owner prefix from owner/repo names" do
      assert UI.workspace_short_name("dalexandre/dev_ide") == "dev_ide"
    end

    test "leaves a bare name untouched" do
      assert UI.workspace_short_name("dev_ide") == "dev_ide"
    end

    test "takes the final segment of a deep path and ignores a trailing slash" do
      assert UI.workspace_short_name("a/b/c/") == "c"
    end

    test "passes through non-binary names" do
      assert UI.workspace_short_name(nil) == nil
    end
  end
end
