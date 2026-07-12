defmodule Ghostty.WindowsPTYTest do
  use ExUnit.Case

  test "keeps a PowerShell process alive for command input and output" do
    assert System.find_executable("powershell.exe") || System.find_executable("pwsh.exe")

    {:ok, pty} = Ghostty.PTY.start_link()

    assert :ok = Ghostty.PTY.write(pty, "Write-Output DEVIDE_WINDOWS_PTY_OK\r\n")
    assert_receive {:data, output}, 10_000
    assert output =~ "DEVIDE_WINDOWS_PTY_OK"
    assert Process.alive?(pty)

    assert :ok = Ghostty.PTY.close(pty)
  end

  test "renders PowerShell output into terminal cells" do
    {:ok, term} = Ghostty.Terminal.start_link(cols: 20, rows: 3)
    assert :ok = Ghostty.Terminal.write(term, "hello\r\nworld")

    state = Ghostty.Terminal.render_state(term)
    assert length(state.cells) == 3
    assert state.cells |> Enum.at(1) |> Enum.take(5) |> Enum.map(&elem(&1, 0)) == ~w(w o r l d)
  end
end
