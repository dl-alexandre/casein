defmodule DevIDE.Loops.Sandbox.GitTest do
  use ExUnit.Case, async: false

  alias DevIDE.Loops.Sandbox.Git
  alias DevIDE.Test.GitRepoCase

  setup do
    %{main: main} = GitRepoCase.setup_git_repo(%{})

    prev = Application.get_env(:dev_ide, DevIDE.Loops)
    on_exit(fn -> restore(DevIDE.Loops, prev) end)

    %{root: main}
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  # Configure the loop as enabled (so Quarantine authorizes) with a fake mix
  # invocation, so no real `mix compile` / `mix test` runs in the worktree.
  defp configure(mix_script) do
    Application.put_env(:dev_ide, DevIDE.Loops,
      enabled: true,
      mix_cmd: {"sh", ["-c", mix_script]}
    )
  end

  defp ctx(root, extra \\ %{}) do
    Map.merge(
      %{root: root, target: "test/frozen_test.exs:1", actor_type: :system, base_sha: "HEAD"},
      extra
    )
  end

  test "evaluates an empty diff with all checks passing", %{root: root} do
    configure("exit 0")

    assert {:ok, eval} = Git.evaluate("", ctx(root))
    assert eval.compile_ok == true
    assert eval.test_pass == true
    assert eval.holdout_pass == true
    assert eval.new_failures == []
  end

  test "reports compile failure when the fake mix returns non-zero", %{root: root} do
    configure("exit 7")

    assert {:ok, eval} = Git.evaluate("", ctx(root))
    assert eval.compile_ok == false
    assert eval.output_excerpt =~ "mix compile failed"
  end

  test "collects held-out new_failures excluding the frozen target", %{root: root} do
    # Fake mix emits one held-out failure id that is not the target.
    configure("echo 'test/other_test.exs:9 failed'; exit 0")

    assert {:ok, eval} = Git.evaluate("", ctx(root))
    assert eval.compile_ok == true
    assert eval.test_pass == true
    assert "test/other_test.exs:9" in eval.new_failures
    assert eval.holdout_pass == false
  end

  test "treats a baseline failure as known, not new", %{root: root} do
    configure("echo 'test/known_test.exs:3 failed'; exit 0")

    extra = %{baseline_failures: ["test/known_test.exs:3"]}
    assert {:ok, eval} = Git.evaluate("", ctx(root, extra))
    assert eval.new_failures == []
    assert eval.holdout_pass == true
  end

  test "marks compile_ok false when the candidate diff does not apply", %{root: root} do
    configure("exit 0")

    assert {:ok, eval} = Git.evaluate("this is not a valid patch\n", ctx(root))
    assert eval.compile_ok == false
    assert eval.output_excerpt =~ "diff did not apply"
  end

  test "returns an error when the loop is not authorized", %{root: root} do
    # No :enabled config -> Policy.can_run_loop? denies.
    Application.put_env(:dev_ide, DevIDE.Loops, mix_cmd: {"sh", ["-c", "exit 0"]})

    assert {:error, _reason} = Git.evaluate("", ctx(root))
  end
end
