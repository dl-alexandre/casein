defmodule DevIDE.Runtimes.PreviewLauncher.SystemRunnerTest do
  use ExUnit.Case, async: true

  alias DevIDE.Runtimes.PreviewLauncher.SystemRunner

  test "start/1 rejects invalid launch specs" do
    assert {:error, :invalid_runtime_preview_launch_spec} = SystemRunner.start(%{})

    assert {:error, :invalid_runtime_preview_launch_spec} =
             SystemRunner.start(%{"command" => ["sh"]})
  end

  test "start/1 runs bash commands in the given cwd" do
    cwd = Path.join(System.tmp_dir!(), "preview-runner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    marker = Path.join(cwd, "ran.txt")

    on_exit(fn -> File.rm_rf(cwd) end)

    spec = %{
      "runtime_id" => "test-runtime",
      "command" => ["bash", "-c", "echo ok > #{marker}"],
      "cwd" => cwd,
      "env" => %{"EXTRA" => "1", :IGNORE => 99}
    }

    assert :ok = SystemRunner.start(spec)
    assert File.read!(marker) == "ok\n"
  end

  test "start/1 returns command failure status for non-zero exits" do
    cwd =
      Path.join(System.tmp_dir!(), "preview-runner-fail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    spec = %{
      "runtime_id" => "fail-runtime",
      "command" => ["bash", "-c", "exit 7"],
      "cwd" => cwd
    }

    assert {:error, {:runtime_preview_command_failed, 7}} = SystemRunner.start(spec)
  end
end
