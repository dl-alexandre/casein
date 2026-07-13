defmodule Ghostty.WindowsPTYTest do
  use ExUnit.Case

  test "keeps a PowerShell process alive for command input and output" do
    assert System.find_executable("powershell.exe") || System.find_executable("pwsh.exe")

    {:ok, pty} = Ghostty.PTY.start_link()

    assert_receive {:data, prompt}, 10_000
    assert prompt =~ "PS "
    assert prompt =~ "> "

    assert :ok = Ghostty.PTY.write(pty, "Write-Output DEVIDE_WINDOWS_PTY_OK\r\n")
    output = receive_until_prompt("")
    assert output =~ "Write-Output DEVIDE_WINDOWS_PTY_OK"
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

  defp receive_until_prompt(output) do
    if String.ends_with?(output, "> ") do
      output
    else
      receive do
        {:data, data} -> receive_until_prompt(output <> data)
      after
        10_000 -> flunk("timed out waiting for the next PowerShell prompt in #{inspect(output)}")
      end
    end
  end
end
