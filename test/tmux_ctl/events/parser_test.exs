defmodule TmuxCtl.Events.ParserTest do
  use ExUnit.Case, async: true

  alias TmuxCtl.Events.Parser

  # Fixture lines lifted from the tmux 3.7 control-mode probe transcript shapes.

  describe "parse_line/1" do
    test "maps sessions-changed" do
      assert {:event, %{type: :sessions_changed, raw: "%sessions-changed"}} =
               Parser.parse_line("%sessions-changed")
    end

    test "maps session-renamed with session_id" do
      assert {:event,
              %{
                type: :session_renamed,
                session_id: "$1",
                window_id: nil,
                pane_id: nil
              }} = Parser.parse_line("%session-renamed $1 my-session")
    end

    test "maps session-window-changed" do
      assert {:event,
              %{
                type: :session_window_changed,
                session_id: "$2",
                window_id: "@3"
              }} = Parser.parse_line("%session-window-changed $2 @3")
    end

    test "maps window-add and folds unlinked-window-add" do
      assert {:event, %{type: :window_add, window_id: "@4"}} =
               Parser.parse_line("%window-add @4")

      assert {:event, %{type: :window_add, window_id: "@5"}} =
               Parser.parse_line("%unlinked-window-add @5")
    end

    test "maps window-close and folds unlinked-window-close" do
      assert {:event, %{type: :window_close, window_id: "@6"}} =
               Parser.parse_line("%window-close @6")

      assert {:event, %{type: :window_close, window_id: "@7"}} =
               Parser.parse_line("%unlinked-window-close @7")
    end

    test "maps window-renamed and folds unlinked-window-renamed" do
      assert {:event, %{type: :window_renamed, window_id: "@8"}} =
               Parser.parse_line("%window-renamed @8 new-name")

      assert {:event, %{type: :window_renamed, window_id: "@9"}} =
               Parser.parse_line("%unlinked-window-renamed @9 other")
    end

    test "maps window-pane-changed" do
      assert {:event,
              %{
                type: :window_pane_changed,
                window_id: "@1",
                pane_id: "%3"
              }} = Parser.parse_line("%window-pane-changed @1 %3")
    end

    test "maps layout-change" do
      assert {:event, %{type: :layout_change, window_id: "@2"}} =
               Parser.parse_line("%layout-change @2 1x2,0,0,0{1x2}")
    end

    test "maps pane-mode-changed" do
      assert {:event, %{type: :pane_mode_changed, pane_id: "%4"}} =
               Parser.parse_line("%pane-mode-changed %4")
    end

    test "maps exit" do
      assert {:event, %{type: :exit}} = Parser.parse_line("%exit")
      assert {:event, %{type: :exit}} = Parser.parse_line("%exit server exited")
    end

    test "begin and end/error block markers" do
      assert :begin = Parser.parse_line("%begin 1784645235 286 0")
      assert :end_block = Parser.parse_line("%end 1784645235 286 0")
      assert :end_block = Parser.parse_line("%error 1784645235 286 0")
    end

    test "fast-drops output, extended-output, and pause" do
      assert :ignore = Parser.parse_line("%output %1 hello world")
      assert :ignore = Parser.parse_line("%extended-output %1 0 0 0 data")
      assert :ignore = Parser.parse_line("%pause %1")
    end

    test "ignores client-local notifications with no topology impact" do
      assert :ignore = Parser.parse_line("%client-session-changed /dev/pts/0 $0 keep")
      assert :ignore = Parser.parse_line("%client-detached /dev/pts/0")
    end

    test "ignores unknown notifications and malformed lines" do
      assert :ignore = Parser.parse_line("%session-changed $0 __devide_keepalive")
      assert :ignore = Parser.parse_line("%future-notification foo bar")
      assert :ignore = Parser.parse_line("not a notification")
      assert :ignore = Parser.parse_line("")
      assert :ignore = Parser.parse_line(nil)
    end

    test "event maps always carry the required keys" do
      assert {:event, event} = Parser.parse_line("%window-add @1")

      assert %{
               type: :window_add,
               server: nil,
               session_id: nil,
               window_id: "@1",
               pane_id: nil,
               raw: "%window-add @1"
             } = event
    end
  end
end
