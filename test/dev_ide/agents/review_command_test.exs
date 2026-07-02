defmodule DevIDE.Agents.ReviewCommandTest do
  use DevIDE.TestCase, async: true
  alias DevIDE.Agents.{ReviewCommand, Capability}

  test "all/0 ids are unique" do
    ids = ReviewCommand.all() |> Enum.map(& &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "all/0 argv values are static lists of binaries — no shell strings" do
    for cmd <- ReviewCommand.all() do
      assert is_list(cmd.argv)
      assert Enum.all?(cmd.argv, &is_binary/1)
    end
  end

  test "fetch/1 returns :error for unknown id" do
    assert :error = ReviewCommand.fetch("nope")
    assert :error = ReviewCommand.fetch("rm -rf /")
    assert :error = ReviewCommand.fetch(nil)
  end

  test "available?/2 requires all `requires` to be :detected" do
    {:ok, cmd} = ReviewCommand.fetch("opencode-version")
    refute ReviewCommand.available?(cmd, [])
    refute ReviewCommand.available?(cmd, [%Capability{kind: :opencode, status: :missing}])
    assert ReviewCommand.available?(cmd, [%Capability{kind: :opencode, status: :detected}])
  end
end
