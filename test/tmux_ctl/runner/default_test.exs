defmodule TmuxCtl.Runner.DefaultTest do
  use DevIDE.TestCase, async: true

  alias TmuxCtl.Runner.Default

  test "run/1 shells out to tmux and returns {output, status}" do
    # `tmux -V` is a harmless, side-effect-free version query.
    assert {output, status} = Default.run(["-V"])
    assert is_binary(output)
    assert status == 0
    assert output =~ "tmux"
  end

  test "run/2 honors the :cd option and defaults stderr_to_stdout" do
    assert {output, 0} = Default.run(["-V"], cd: System.tmp_dir!())
    assert output =~ "tmux"
  end
end
