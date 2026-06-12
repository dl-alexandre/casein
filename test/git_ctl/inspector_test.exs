defmodule GitCtl.InspectorTest do
  use ExUnit.Case, async: true

  alias GitCtl.Inspector

  test "returns error for missing paths" do
    assert Inspector.inspect_cwd("/non/existent/path") == :error
  end

  test "infers agent from path patterns" do
    assert Inspector.infer_agent("/home/dev/.claude/worktrees/fix") == "claude"
    assert Inspector.infer_agent("/tmp/project") == nil
  end
end
