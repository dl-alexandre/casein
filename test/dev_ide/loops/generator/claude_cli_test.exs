defmodule DevIDE.Loops.Generator.ClaudeCliTest do
  use ExUnit.Case, async: false

  alias DevIDE.Loops.Generator.ClaudeCli

  setup do
    prev = Application.get_env(:dev_ide, DevIDE.Loops)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, DevIDE.Loops, prev),
        else: Application.delete_env(:dev_ide, DevIDE.Loops)
    end)

    :ok
  end

  defp ctx do
    %{
      target: "test/x_test.exs:1",
      baseline_failures: [],
      feedback: "",
      prior_diff: nil,
      iteration: 1,
      root: nil
    }
  end

  defp configure(runner) do
    Application.put_env(:dev_ide, DevIDE.Loops, cli_runner: runner)
  end

  defp arg_after(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)

  test "invokes claude headlessly and returns the printed diff (fences stripped)" do
    test_pid = self()

    runner = fn args, _opts ->
      send(test_pid, {:args, args})
      {"```diff\n--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@\n-x\n+y\n```\n", 0}
    end

    configure(runner)

    assert {:ok, %{diff: diff, notes: "claude-cli"}} = ClaudeCli.generate(ctx())
    assert diff == "--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@\n-x\n+y\n"

    assert_received {:args, args}
    assert "-p" in args
    assert "--output-format" in args
    assert arg_after(args, "--model") == "claude-opus-4-8"
    # the prompt arg carries the target + the diff-only instruction
    assert arg_after(args, "-p") =~ "test/x_test.exs:1"
    assert arg_after(args, "--append-system-prompt") =~ "ONLY a unified git diff"
  end

  test "non-zero exit surfaces an error" do
    configure(fn _args, _opts -> {"command not found", 127} end)
    assert {:error, {:claude_cli, 127, _}} = ClaudeCli.generate(ctx())
  end

  test "a raised exception in the runner is caught" do
    configure(fn _args, _opts -> raise "boom" end)
    assert {:error, {:claude_cli_failed, _}} = ClaudeCli.generate(ctx())
  end
end
