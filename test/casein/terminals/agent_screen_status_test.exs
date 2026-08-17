defmodule Casein.Terminals.AgentScreenStatusTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.AgentScreenStatus

  describe "classify/1" do
    for {name, screen, expected} <- [
          {"OpenCode permission dialog",
           "Permission required\n❯ Allow once\n  Always allow\n  Reject", :permission_prompt},
          {"Cursor approval dialog with ANSI",
           "\e[33mThis command needs your approval\e[0m\n  1. Yes\n❯ 2. No", :permission_prompt},
          {"inline yes/no approval", "Do you want to execute this command? [y/N]",
           :permission_prompt},
          {"OpenCode working footer", "editing lib/a.ex\nesc to interrupt", :working},
          {"spinner working footer", "⠋ Thinking", :working},
          {"no evidence", "finished the requested edit\n$", :unknown},
          {"non-binary input", nil, :unknown}
        ] do
      test name do
        assert AgentScreenStatus.classify(unquote(screen)) == unquote(expected)
      end
    end

    test "ignores stale permission prompts outside the deeper attention tail" do
      stale = "Permission required\n❯ Allow once\nReject"
      current = Enum.map_join(1..9, "\n", &"current output #{&1}")

      assert AgentScreenStatus.classify(stale <> "\n" <> current) == :unknown
    end

    test "uses a shallower tail for working footer hints" do
      screen = "esc to interrupt\nnew line 1\nnew line 2\nnew line 3"

      assert AgentScreenStatus.classify(screen) == :unknown
    end

    test "does not self-match prose about permission prompts" do
      screen = """
      The issue says a pane may contain the literal string \"needs your approval\".
      It also discusses labels such as Allow once and Reject in ordinary prose.
      This paragraph is documentation, not an interactive approval dialog.
      """

      assert AgentScreenStatus.classify(screen) == :unknown
    end

    test "requires an interactive choice alongside a permission phrase" do
      assert AgentScreenStatus.classify("Permission required for this operation") == :unknown
    end
  end
end
