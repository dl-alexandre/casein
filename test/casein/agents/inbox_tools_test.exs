defmodule Casein.Agents.InboxToolsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AgentEvents
  alias Casein.Agents.TerminalTools.Impl.Agent
  alias Casein.Terminals.Tmux

  @workspace "alpha"

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      fake_tmux_windows: TmuxCtl.Test.FakeState.get(:fake_tmux_windows),
      fake_tmux_panes: TmuxCtl.Test.FakeState.get(:fake_tmux_panes),
      fake_tmux_test_pid: TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    }

    AgentEvents.clear()
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    session = Tmux.workspace_session_prefix(@workspace) <> "u-dev"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{id: "@1", index: 0, name: "orchestrator", active: true, panes: 1, activity: 5},
        %{id: "@2", index: 1, name: "api-gateway", active: false, panes: 1, activity: 5}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          title: "orchestrator",
          role: "agent"
        },
        %{id: "%3", window_id: "@2", index: 0, active: true, title: "api-gateway", role: "agent"}
      ]
    })

    on_exit(fn ->
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, previous.fake_tmux_test_pid)

      if previous.tmux_adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:casein, :tmux_adapter)

      AgentEvents.clear()
    end)

    %{session: session}
  end

  describe "say/1" do
    test "a message addressed by exact pane reaches that mailbox", %{session: session} do
      assert {:ok, sent} = say(session, %{"to" => "pane:%3", "body" => "rebase before auth"})

      assert sent.to == "pane:%3"
      assert sent.from == "pane:%1"
      assert sent.status == "sent"

      assert {:ok, %{messages: [message], count: 1}} = inbox(session, %{"address" => "pane:%3"})
      assert message.body == "rebase before auth"
      assert message.from == "pane:%1"
    end

    test "a window name resolves to that window's agent pane", %{session: session} do
      assert {:ok, %{to: "pane:%3"}} = say(session, %{"to" => "api-gateway", "body" => "hi"})
    end

    test "a bare pane id is accepted", %{session: session} do
      assert {:ok, %{to: "pane:%3"}} = say(session, %{"to" => "%3", "body" => "hi"})
    end

    test "an unknown recipient is refused rather than given a new mailbox", %{session: session} do
      assert {:error, :unknown_recipient} = say(session, %{"to" => "nobody", "body" => "hi"})
    end

    test "an empty body is refused rather than delivered", %{session: session} do
      assert {:error, _} = say(session, %{"to" => "pane:%3", "body" => "   "})
    end

    test "a retried send does not duplicate the message", %{session: session} do
      args = %{"to" => "pane:%3", "body" => "once", "message_id" => "retry-1"}

      assert {:ok, %{status: "sent"}} = say(session, args)
      assert {:ok, %{status: "duplicate"}} = say(session, args)
      assert {:ok, %{count: 1}} = inbox(session, %{"address" => "pane:%3"})
    end
  end

  describe "inbox/1" do
    test "an agent reads its own mailbox with no address", %{session: session} do
      say(session, %{"to" => "pane:%3", "body" => "for you"})

      # caller_pane is injected by MCP scope resolution; the agent passes nothing.
      assert {:ok, %{address: "pane:%3", messages: [%{body: "for you"}]}} =
               inbox(session, %{}, "%3")
    end

    test "peeking leaves the message; collecting removes it", %{session: session} do
      say(session, %{"to" => "pane:%3", "body" => "act on me"})

      assert {:ok, %{count: 1, collected: false}} = inbox(session, %{}, "%3")
      # Still there: peeking is not acting.
      assert {:ok, %{count: 1}} = inbox(session, %{}, "%3")

      assert {:ok, %{count: 1, collected: true}} = inbox(session, %{"collect" => true}, "%3")
      assert {:ok, %{count: 0}} = inbox(session, %{}, "%3")
    end

    test "one agent's mailbox is not another's", %{session: session} do
      say(session, %{"to" => "pane:%3", "body" => "for three"})

      assert {:ok, %{count: 1}} = inbox(session, %{}, "%3")
      assert {:ok, %{count: 0}} = inbox(session, %{}, "%1")
    end

    test "reading with no address and no caller pane is an error, not everyone's mail", %{
      session: session
    } do
      assert {:error, :no_inbox_address} =
               Agent.inbox(%{"workspace_id" => @workspace, "session" => session})
    end
  end

  ## Helpers

  defp say(session, args, caller \\ "%1") do
    Agent.say(
      Map.merge(
        %{"workspace_id" => @workspace, "session" => session, "caller_pane" => caller},
        args
      )
    )
  end

  defp inbox(session, args, caller \\ "%1") do
    Agent.inbox(
      Map.merge(
        %{"workspace_id" => @workspace, "session" => session, "caller_pane" => caller},
        args
      )
    )
  end
end
