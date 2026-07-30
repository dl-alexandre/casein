defmodule Ghostty.WindowsPTYTest do
  use ExUnit.Case

  test "keeps a PowerShell process alive for command input and output" do
    assert System.find_executable("powershell.exe") || System.find_executable("pwsh.exe")

    {:ok, pty} = Ghostty.PTY.start_link(cwd: "C:\\")

    prompt = receive_until_prompt("")
    assert prompt =~ "PS C:\\>"

    assert :ok = Ghostty.PTY.write(pty, "Write-Output CASEIN_WINDOWS_PTY_OK\r")
    output = receive_until_prompt("")
    assert output =~ "Write-Output"
    assert output =~ "CASEIN_WINDOWS_PTY_OK"
    assert Process.alive?(pty)

    assert :ok = Ghostty.PTY.close(pty)
  end

  test "passes a scoped environment into the child console" do
    {:ok, pty} =
      Ghostty.PTY.start_link(cwd: "C:\\", env: %{"CASEIN_PTY_ENV_TEST" => "workspace-scoped"})

    _prompt = receive_until_prompt("")
    assert :ok = Ghostty.PTY.write(pty, "Write-Output $env:CASEIN_PTY_ENV_TEST\r")
    output = receive_until_prompt("")
    assert output =~ "workspace-scoped"
    assert :ok = Ghostty.PTY.close(pty)
  end

  test "closing the PTY terminates descendants in its Windows Job Object" do
    {:ok, pty} = Ghostty.PTY.start_link(cwd: "C:\\")
    _prompt = receive_until_prompt("")

    command =
      "$child = Start-Process powershell.exe " <>
        "-ArgumentList '-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 120' " <>
        "-PassThru; Write-Output CASEIN_CHILD_PID=$($child.Id)\r"

    assert :ok = Ghostty.PTY.write(pty, command)
    output = receive_until_prompt("")
    [_, pid] = Regex.run(~r/CASEIN_CHILD_PID=(\d+)/, output)

    assert :ok = Ghostty.PTY.close(pty)

    verification =
      "$process = Get-Process -Id #{pid} -ErrorAction SilentlyContinue; " <>
        "if ($process) { [void]$process.WaitForExit(5000); " <>
        "if (-not $process.HasExited) { " <>
        "Write-Output ('still-running pid={0} name={1}' -f $process.Id, $process.ProcessName); " <>
        "exit 1 } }; exit 0"

    assert {_output, 0} =
             System.cmd("powershell.exe", ["-NoLogo", "-NoProfile", "-Command", verification],
               stderr_to_stdout: true
             )
  end

  test "renders PowerShell output into terminal cells" do
    {:ok, term} = Ghostty.Terminal.start_link(cols: 20, rows: 3)
    assert :ok = Ghostty.Terminal.write(term, "hello\r\nworld")

    state = Ghostty.Terminal.render_state(term)
    assert length(state.cells) == 3
    assert state.cells |> Enum.at(1) |> Enum.take(5) |> Enum.map(&elem(&1, 0)) == ~w(w o r l d)
  end

  test "applies VT cursor movement, erasure, and split control sequences" do
    {:ok, term} = Ghostty.Terminal.start_link(cols: 12, rows: 3)

    assert :ok = Ghostty.Terminal.write(term, "old text\rnew")
    assert :ok = Ghostty.Terminal.write(term, "\e[2")
    assert :ok = Ghostty.Terminal.write(term, "J\e[Hnormal")

    state = Ghostty.Terminal.render_state(term)
    first_row = state.cells |> hd() |> Enum.map_join(&elem(&1, 0))

    assert first_row == "normal"
    assert state.cursor == %{x: 6, y: 0, visible: true, shape: :block, color: nil}
  end

  test "encodes Windows console Enter as one carriage return" do
    assert Ghostty.LiveTerminal.handle_key(self(), %{"key" => "Enter"}) == {:ok, "\r"}
  end

  test "encodes control keys without emitting modifier names" do
    assert Ghostty.LiveTerminal.handle_key(self(), %{"key" => "c", "ctrlKey" => true}) ==
             {:ok, <<3>>}

    assert Ghostty.LiveTerminal.handle_key(self(), %{"key" => "Control", "ctrlKey" => true}) ==
             :none

    assert Ghostty.LiveTerminal.handle_key(self(), %{"key" => "F1"}) == :none
  end

  test "delays right-margin wrapping until the next printable character" do
    {:ok, term} = Ghostty.Terminal.start_link(cols: 5, rows: 2)

    assert :ok = Ghostty.Terminal.write(term, "abcde")
    assert Ghostty.Terminal.render_state(term).cursor.x == 4
    assert Ghostty.Terminal.render_state(term).cursor.y == 0

    assert :ok = Ghostty.Terminal.write(term, "f")
    state = Ghostty.Terminal.render_state(term)
    assert state.cursor.x == 1
    assert state.cursor.y == 1
  end

  test "answers cursor-position queries for interactive line editors" do
    {:ok, term} = Ghostty.Terminal.start_link(cols: 20, rows: 4, owner: self())

    assert :ok = Ghostty.Terminal.write(term, "prompt> \e[6n")
    assert_receive {:pty_write, "\e[1;9R"}
  end

  defp receive_until_prompt(output) do
    if Regex.match?(~r/PS [^\r\n]*>/, output) do
      output
    else
      receive do
        {:data, data} -> receive_until_prompt(output <> data)
        {:bridge_error, data} -> flunk("ConPTY bridge failed: #{data}")
        {:exit, status} -> flunk("ConPTY bridge exited with status #{inspect(status)}")
      after
        10_000 -> flunk("timed out waiting for the next PowerShell prompt in #{inspect(output)}")
      end
    end
  end
end
