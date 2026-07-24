defmodule Casein.Desktop.TerminalBackend do
  @moduledoc """
  Selects the desktop terminal implementation once at runtime.

  Windows uses the native PowerShell/ConPTY session. Unix desktop builds keep
  the full tmux/Ghostty cockpit, including workspace sessions and zsh support.
  """

  @type t :: :powershell | :tmux

  @spec default(:os.type()) :: t()
  def default({:win32, _}), do: :powershell
  def default(_), do: :tmux

  @spec current() :: t()
  def current do
    Application.get_env(:dev_ide, :desktop_terminal_backend, default(:os.type()))
  end

  def powershell?, do: current() == :powershell
  def tmux?, do: current() == :tmux

  @doc "Whether the desktop-only native terminal session should replace tmux."
  def native_session?(desktop_mode? \\ Application.get_env(:dev_ide, :desktop_mode, false)) do
    desktop_mode? and powershell?()
  end
end
