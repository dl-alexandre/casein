defmodule TmuxCtl.Runner.DefaultTest do
  use ExUnit.Case, async: true

  alias TmuxCtl.Runner.Default

  @tag :requires_tmux
  test "run/2 returns tmux version output for -V" do
    unless tmux_available?(), do: :ok

    {output, exit_code} = Default.run(["-V"], [])

    assert exit_code == 0
    assert output =~ "tmux"
  end

  defp tmux_available? do
    case System.find_executable("tmux") do
      nil ->
        false

      _ ->
        try do
          {_output, exit_code} = System.cmd("tmux", ["-V"], stderr_to_stdout: true)
          exit_code == 0
        rescue
          _ -> false
        catch
          :exit, _ -> false
        end
    end
  end
end
