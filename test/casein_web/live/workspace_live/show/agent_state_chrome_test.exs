defmodule CaseinWeb.WorkspaceLive.Show.AgentStateChromeTest do
  use ExUnit.Case, async: true

  alias CaseinWeb.WorkspaceLive.Show.AgentStateChrome

  describe "present/2" do
    test "covers all seven AgentState values with distinct chrome" do
      states = [:working, :blocked, :done, :idle, :errored, :stalled, :unknown]

      presentations =
        Map.new(states, fn state ->
          {state, AgentStateChrome.present(state)}
        end)

      assert presentations.working.known?
      assert presentations.working.overrides_activity?
      assert presentations.working.dot_class =~ "success"
      assert presentations.working.chip_text == nil
      assert presentations.working.label == "Agent pane working"

      assert presentations.blocked.chip_text == "needs input"
      assert presentations.blocked.dot_class =~ "error"
      assert presentations.blocked.label =~ "blocked"

      assert presentations.done.chip_text == "done"
      assert presentations.done.dot_class =~ "info"

      assert presentations.idle.known?
      assert presentations.idle.chip_text == nil
      assert presentations.idle.dot_class =~ "base-content"

      assert presentations.errored.chip_text == "error"
      assert presentations.errored.dot_class =~ "error"
      assert presentations.errored.label =~ "errored"

      assert presentations.stalled.chip_text == "stalled"
      assert presentations.stalled.dot_class =~ "warning"
      assert presentations.stalled.label =~ "wedged"

      refute presentations.unknown.known?
      refute presentations.unknown.overrides_activity?
      assert presentations.unknown.dot_class == nil
      assert presentations.unknown.chip_text == nil
      assert presentations.unknown.label == nil
    end

    test "unknown does not invent idle or ready certainty" do
      chrome = AgentStateChrome.present(nil)
      refute chrome.known?
      assert chrome.state == :unknown
      assert AgentStateChrome.present(:ready).state == :unknown
    end

    test "blocked and done stay visually distinct (ready problem)" do
      blocked = AgentStateChrome.present(:blocked, "permission")
      done = AgentStateChrome.present(:done)

      refute blocked.chip_text == done.chip_text
      refute blocked.dot_class == done.dot_class
      assert blocked.label =~ "permission"
    end

    test "stalled is warning, not the working success pulse alone" do
      working = AgentStateChrome.present(:working)
      stalled = AgentStateChrome.present(:stalled)

      assert working.dot_class =~ "success"
      assert stalled.dot_class =~ "warning"
      refute stalled.dot_class == working.dot_class
      assert stalled.chip_text == "stalled"
    end
  end

  describe "apply_to_activity/4" do
    test "unknown keeps the activity pair (honest degradation)" do
      assert AgentStateChrome.apply_to_activity("bg-keep", "keep me", :unknown) ==
               {"bg-keep", "keep me"}

      assert AgentStateChrome.apply_to_activity("bg-keep", "keep me", nil) ==
               {"bg-keep", "keep me"}
    end

    test "known states replace activity colour and label" do
      {class, label} =
        AgentStateChrome.apply_to_activity("bg-keep", "keep me", :stalled, nil)

      assert class =~ "warning"
      assert label =~ "wedged"
    end
  end

  describe "task_title/3" do
    test "appends chrome label only when state is known" do
      assert AgentStateChrome.task_title("Fix auth", :blocked, "needs permission") ==
               "Fix auth · Agent blocked: needs permission"

      assert AgentStateChrome.task_title("Fix auth", :unknown, nil) == "Fix auth"
      assert AgentStateChrome.task_title(nil, :done, nil) == "Agent done"
      assert AgentStateChrome.task_title(nil, :unknown, nil) == nil
    end
  end
end
