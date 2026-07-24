defmodule Casein.Terminals.PaneInteractionTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.PaneInteraction

  test "agent_pane? matches role and agent commands" do
    assert PaneInteraction.agent_pane?(%{role: "agent", current_command: "node"})
    assert PaneInteraction.agent_pane?(%{current_command: "grok"})
    assert PaneInteraction.agent_pane?("claude")
    refute PaneInteraction.agent_pane?(%{role: "operator", current_command: "bash"})
    refute PaneInteraction.agent_pane?("bash")
  end

  test "path_format and scroll_policy share agent detection" do
    assert PaneInteraction.path_format(%{role: "agent"}) == "agent"
    assert PaneInteraction.scroll_policy(%{role: "agent"}) == "agent"
    assert PaneInteraction.path_format("grok") == "agent"
    assert PaneInteraction.scroll_policy("grok") == "agent"
    assert PaneInteraction.path_format("bash") == "shell"
    assert PaneInteraction.scroll_policy("bash") == "shell"
  end

  test "scroll_backend defaults for agent and shell" do
    assert PaneInteraction.scroll_backend("grok") == "sgr_mouse"
    assert PaneInteraction.scroll_backend("bash") == "emulator"
  end
end
