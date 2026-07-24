defmodule Casein.Terminals.CommandLogTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.{CommandLog, PaneCommand}

  setup do
    CommandLog.reset!()
    :ok
  end

  test "stores newest records first and filters by sequence" do
    for seq <- 1..3 do
      :ok =
        CommandLog.append(%PaneCommand{
          id: "cmd-#{seq}",
          workspace_id: "ws-log",
          sid: "sid-log",
          seq: seq,
          command: "cmd #{seq}",
          started_at: DateTime.utc_now()
        })
    end

    assert [%{seq: 3}, %{seq: 2}] = CommandLog.list("ws-log", "sid-log", last_n: 2)
    assert [%{seq: 3}] = CommandLog.list("ws-log", "sid-log", since_seq: 2)
  end

  test "keeps pane-scoped records separate" do
    :ok =
      CommandLog.append(%PaneCommand{
        id: "pane-1",
        workspace_id: "ws-pane-log",
        sid: "sid-pane-log",
        pane_id: "%1",
        seq: 1,
        command: "one",
        started_at: DateTime.utc_now()
      })

    :ok =
      CommandLog.append(%PaneCommand{
        id: "pane-2",
        workspace_id: "ws-pane-log",
        sid: "sid-pane-log",
        pane_id: "%2",
        seq: 2,
        command: "two",
        started_at: DateTime.utc_now()
      })

    assert [%{pane_id: "%2"}] = CommandLog.list("ws-pane-log", "sid-pane-log", pane_id: "%2")
    assert [%{seq: 2}, %{seq: 1}] = CommandLog.list("ws-pane-log", "sid-pane-log")
  end
end
