defmodule Casein.Terminals.TuiSurfaceTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.TuiSurface

  test "classifies Claude Code's agents view from the new-session field" do
    excerpt = """
    Agents
    Background sessions

    describe a task for a new session
    """

    assert TuiSurface.classify(excerpt) == :agents_view
    assert TuiSurface.name(:agents_view) == "agents_view"
    refute TuiSurface.conversation?(:agents_view)
    refute TuiSurface.conversation_submit?(:agents_view)
  end

  test "classifies a permission menu" do
    excerpt = "Claude wants to edit lib/foo.ex\nDo you want to proceed?\nAllow  Deny"

    assert TuiSurface.classify(excerpt) == :menu
    refute TuiSurface.conversation?(:menu)
  end

  test "classifies a busy conversation footer" do
    assert TuiSurface.classify("working on the brief\nesc to interrupt") == :conversation
    assert TuiSurface.conversation?(:conversation)
    assert TuiSurface.conversation_submit?(:conversation)
  end

  test "unclassified or empty captures are unknown and allowed" do
    assert TuiSurface.classify("") == :unknown
    assert TuiSurface.classify("# Casein agent pane\n") == :unknown
    assert TuiSurface.classify(nil) == :unknown
    assert TuiSurface.conversation?(:unknown)
    assert TuiSurface.conversation_submit?(:unknown)
  end

  test "agents view wins over conversation chrome on the same screen" do
    excerpt = "esc to interrupt\ndescribe a task for a new session"

    assert TuiSurface.classify(excerpt) == :agents_view
  end

  test "submitted:true is stripped on a non-conversation surface" do
    refute TuiSurface.honest_submitted(:agents_view, true)
    refute TuiSurface.honest_submitted(:menu, true)
    assert TuiSurface.honest_submitted(:conversation, true) == true
    assert TuiSurface.honest_submitted(:unknown, true) == true
    assert TuiSurface.honest_submitted(:agents_view, false) == false
    assert TuiSurface.honest_submitted(:agents_view, nil) == nil
  end
end
