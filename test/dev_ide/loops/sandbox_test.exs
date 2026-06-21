defmodule DevIDE.Loops.SandboxTest do
  use ExUnit.Case, async: true

  alias DevIDE.Loops.Sandbox

  describe "analyze_diff/1 — diff-derived gaming signals" do
    test "flags a diff that touches a file under test/" do
      diff = """
      --- a/test/foo_test.exs
      +++ b/test/foo_test.exs
      @@ -1 +1 @@
      -  assert foo() == 1
      +  assert foo() == 2
      """

      assert %{touched_test_files: true} = Sandbox.analyze_diff(diff)
    end

    test "a lib-only diff does not flag touched tests" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1 +1 @@
      -  def foo, do: 1
      +  def foo, do: 2
      """

      assert %{touched_test_files: false} = Sandbox.analyze_diff(diff)
    end

    test "flags an added bare rescue" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1 +3 @@
      +  try do
      +    risky()
      +  rescue
      +    _ -> :ok
      +  end
      """

      assert %{added_rescue: true} = Sandbox.analyze_diff(diff)
    end

    test "a specific rescue clause is not flagged" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1 +1 @@
      +  rescue e in RuntimeError -> {:error, e}
      """

      assert %{added_rescue: false} = Sandbox.analyze_diff(diff)
    end
  end
end
