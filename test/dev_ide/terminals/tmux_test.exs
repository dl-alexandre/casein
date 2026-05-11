defmodule DevIDE.Terminals.TmuxTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.Tmux

  test "session_name uses the devide: prefix" do
    assert "devide:" <> _ = Tmux.session_name("alice", "u-1")
  end

  test "sanitizes unsafe characters in workspace name and sid" do
    name = Tmux.session_name("alice; rm -rf /", "u 1$")
    assert name =~ ~r/^devide:[A-Za-z0-9_\-]+:[A-Za-z0-9_\-]+$/
  end

  test "is deterministic for the same inputs" do
    assert Tmux.session_name("alice", "u-1") == Tmux.session_name("alice", "u-1")
  end
end
