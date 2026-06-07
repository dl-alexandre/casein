defmodule DevIDE.Terminals.TmuxTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.Tmux

  test "session_name uses the devide_ prefix" do
    assert "devide_" <> _ = Tmux.session_name("alice", "u-1")
  end

  test "sanitizes unsafe characters in workspace name and sid" do
    name = Tmux.session_name("alice; rm -rf /", "u 1$")
    assert name =~ ~r/^devide_[A-Za-z0-9_\-]+_[A-Za-z0-9_\-]+$/
  end

  test "is deterministic for the same inputs" do
    assert Tmux.session_name("alice", "u-1") == Tmux.session_name("alice", "u-1")
  end

  test "resize_pane rejects invalid directions and amounts" do
    assert Tmux.resize_amount_default() == 5
    assert Tmux.resize_amount_max() == 50

    assert {:error, :invalid_resize} = Tmux.resize_pane("devide_alpha_ws-1", "%1", "side", 5)
    assert {:error, :invalid_amount} = Tmux.resize_pane("devide_alpha_ws-1", "%1", "left", 0)
    assert {:error, :invalid_amount} = Tmux.resize_pane("devide_alpha_ws-1", "%1", "left", 51)
  end
end
