defmodule DevIDE.Desktop.TerminalBackendTest do
  use ExUnit.Case, async: false

  alias DevIDE.Desktop.TerminalBackend

  test "selects PowerShell only for Windows" do
    assert TerminalBackend.default({:win32, :nt}) == :powershell
    assert TerminalBackend.default({:unix, :darwin}) == :tmux
    assert TerminalBackend.default({:unix, :linux}) == :tmux
  end

  test "runtime override makes platform routing testable" do
    previous = Application.get_env(:dev_ide, :desktop_terminal_backend)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dev_ide, :desktop_terminal_backend, previous),
        else: Application.delete_env(:dev_ide, :desktop_terminal_backend)
    end)

    Application.put_env(:dev_ide, :desktop_terminal_backend, :powershell)
    assert TerminalBackend.powershell?()
    refute TerminalBackend.tmux?()
    assert TerminalBackend.native_session?(true)
    refute TerminalBackend.native_session?(false)

    Application.put_env(:dev_ide, :desktop_terminal_backend, :tmux)
    refute TerminalBackend.native_session?(true)
  end
end
