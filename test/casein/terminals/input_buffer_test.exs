defmodule Casein.Terminals.InputBufferTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.InputBuffer

  describe "classify/1" do
    test "empty composer is empty input" do
      screen = """
      finished the requested edit

      ❯
        54.9K (11%)  ·  claude-sonnet  ·  ⏎ send
      """

      assert InputBuffer.classify(screen) == %{has_content: false, source: "empty"}
    end

    test "faint suggested prompt is placeholder, not typed content" do
      screen = """
      finished the requested edit

      ❯  \e[2mswitch gh to my account mbaldin\e[22m
        54.9K (11%)  ·  claude-sonnet  ·  ⏎ send
      """

      assert InputBuffer.classify(screen) == %{has_content: false, source: "placeholder"}
    end

    test "whole-line faint composer is placeholder" do
      screen = """
      done

      \e[2m❯  open an issue for those dead CSS rules\e[0m
        12.0K (3%)  ·  claude-sonnet  ·  ⏎ send
      """

      assert InputBuffer.classify(screen) == %{has_content: false, source: "placeholder"}
    end

    test "gray 256-color composer text is placeholder" do
      screen = """
      done

      ❯  \e[38;5;244mkeep the label attr, don't revert it\e[39m
        1.0K (1%)  ·  claude-sonnet  ·  ⏎ send
      """

      assert InputBuffer.classify(screen) == %{has_content: false, source: "placeholder"}
    end

    test "typed composer with ANSI elsewhere is real unsent text" do
      screen = """
      \e[38;5;39m❯\e[0m  now implement the acceptance criteria on this branch
        54.9K (11%)  ·  claude-sonnet  ·  ⏎ send
      """

      assert InputBuffer.classify(screen) == %{has_content: true, source: "typed"}
    end

    test "composer text mentioning a runtime name is not treated as a footer" do
      screen = """
      done

      ❯  \e[2mfix the opencode launcher\e[22m
        1.0K (1%)  ·  claude-sonnet  ·  ⏎ send
      """

      assert InputBuffer.classify(screen) == %{has_content: false, source: "placeholder"}
    end

    test "plain composer text without ANSI is unknown, not typed" do
      screen = """
      finished the requested edit

      ❯  switch gh to my account mbaldin
        54.9K (11%)  ·  claude-sonnet  ·  ⏎ send
      """

      assert InputBuffer.classify(screen) == %{has_content: "unknown", source: "unknown"}
    end

    test "permission-menu chevron is not a composer" do
      screen = """
      Permission required
      ❯ Allow once
        Always allow
        Reject
      """

      assert InputBuffer.classify(screen) == %{has_content: "unknown", source: "unknown"}
    end

    test "working footer without a composer is unknown" do
      assert InputBuffer.classify("editing lib/a.ex\nesc to interrupt") ==
               %{has_content: "unknown", source: "unknown"}
    end

    test "plain output without a composer is unknown" do
      assert InputBuffer.classify("ready\n") == %{has_content: "unknown", source: "unknown"}
    end

    test "non-binary input is unknown" do
      assert InputBuffer.classify(nil) == %{has_content: "unknown", source: "unknown"}
    end
  end
end
