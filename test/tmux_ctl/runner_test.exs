defmodule TmuxCtl.RunnerTest do
  use Casein.TestCase, async: false

  alias TmuxCtl.Runner
  alias TmuxCtl.Test.FakeRunner

  setup do
    previous = Application.get_env(:tmux_ctl, :runner)

    Application.put_env(:tmux_ctl, :runner, FakeRunner)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tmux_ctl, :runner, previous),
        else: Application.delete_env(:tmux_ctl, :runner)
    end)

    :ok
  end

  test "configured returns the application runner module" do
    assert Runner.configured() == FakeRunner
  end

  test "run delegates to the configured runner" do
    assert {"", 0} = Runner.run(["list-windows", "-t", "casein_alpha_main", "-F", "fmt"])
  end

  test "argv prefixes tmux when the runner does not implement argv/2" do
    assert ["tmux", "list-windows"] = Runner.argv(["list-windows"])
  end

  test "argv uses the runner implementation when present" do
    assert ["tmux", "resize-pane"] = FakeRunner.argv(["resize-pane"], [])
  end
end
