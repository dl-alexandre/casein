defmodule Casein.Agents.TerminalToolsNextPromptTest do
  @moduledoc """
  Round-trips the next-prompt MCP tools through `TerminalTools.invoke/2`, so
  schema validation, pane resolution, and payload shaping are covered the way an
  orchestrator actually reaches them.
  """
  use Casein.TestCase, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.NextPrompt
  alias Casein.Terminals.Tmux
  alias TmuxCtl.Test.FakeState

  @workspace "alpha"
  @agent_pane "%2"

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      deliver: Application.get_env(:casein, :next_prompt_deliver),
      windows: FakeState.get(:fake_tmux_windows),
      panes: FakeState.get(:fake_tmux_panes),
      scrollback: FakeState.get(:fake_tmux_scrollback),
      test_pid: FakeState.get(:fake_tmux_test_pid)
    }

    test_pid = self()

    Application.put_env(:casein, :next_prompt_deliver, fn entry, trigger ->
      send(test_pid, {:delivered, entry, trigger})
      {:ok, %{delivery: :delivered}}
    end)

    session = Tmux.session_name(@workspace, "main")
    seed_session(session)
    NextPrompt.clear()
    AgentState.clear()

    on_exit(fn ->
      NextPrompt.clear()
      AgentState.clear()
      FakeState.restore(:fake_tmux_windows, previous.windows)
      FakeState.restore(:fake_tmux_panes, previous.panes)
      FakeState.restore(:fake_tmux_scrollback, previous.scrollback)
      FakeState.restore(:fake_tmux_test_pid, previous.test_pid)

      if previous.tmux_adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:casein, :tmux_adapter)

      if previous.deliver,
        do: Application.put_env(:casein, :next_prompt_deliver, previous.deliver),
        else: Application.delete_env(:casein, :next_prompt_deliver)
    end)

    {:ok, session: session}
  end

  defp seed_session(session) do
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    FakeState.put(:fake_tmux_test_pid, self())

    FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "work",
          active: true,
          panes: 2,
          activity: 10,
          current_command: "bash"
        }
      ]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 80,
          height: 40,
          current_command: "bash",
          current_path: "/workspace"
        },
        %{
          id: @agent_pane,
          window_id: "@1",
          index: 1,
          active: false,
          left: 80,
          top: 0,
          width: 80,
          height: 40,
          current_command: "bash",
          current_path: "/workspace"
        }
      ]
    })

    FakeState.put(:fake_tmux_scrollback, %{{session, @agent_pane} => "# Casein agent pane\n"})
  end

  test "set → get → clear round-trips through the MCP surface", %{session: session} do
    assert {:ok, set} =
             TerminalTools.invoke("terminal_set_next_prompt", %{
               "workspace_id" => @workspace,
               "pane" => @agent_pane,
               "text" => "rebase onto master before you push",
               "deliver_when" => "next_done",
               "coalesce_key" => "orchestrator-1"
             })

    assert set.status == "pending"
    assert set.target == @agent_pane
    assert set.deliver_when == "next_done"
    assert set.replaced_pending == false
    assert is_binary(set.expires_at)

    assert {:ok, got} =
             TerminalTools.invoke("terminal_get_next_prompt", %{
               "workspace_id" => @workspace,
               "pane" => @agent_pane
             })

    assert got.pending_next_prompt == true
    assert got.text == "rebase onto master before you push"
    assert got.coalesce_key == "orchestrator-1"

    assert {:ok, cleared} =
             TerminalTools.invoke("terminal_clear_next_prompt", %{
               "workspace_id" => @workspace,
               "pane" => @agent_pane
             })

    assert cleared.status == "cleared"
    assert NextPrompt.get(session, @agent_pane) == nil
  end

  test "a second set reports that it replaced the first" do
    {:ok, _} = set_prompt("first", "orch-a")

    assert {:ok, second} = set_prompt("second", "orch-b")
    assert second.replaced_pending == true
    assert second.replaced_coalesce_key == "orch-a"
  end

  test "clearing with someone else's coalesce_key is a no-op" do
    {:ok, _} = set_prompt("from B", "b")

    assert {:ok, %{status: "not_pending"}} =
             TerminalTools.invoke("terminal_clear_next_prompt", %{
               "workspace_id" => @workspace,
               "pane" => @agent_pane,
               "coalesce_key" => "a"
             })

    assert {:ok, %{pending_next_prompt: true}} =
             TerminalTools.invoke("terminal_get_next_prompt", %{
               "workspace_id" => @workspace,
               "pane" => @agent_pane
             })
  end

  test "an unknown deliver_when is rejected, not defaulted" do
    assert {:error, error} =
             TerminalTools.invoke("terminal_set_next_prompt", %{
               "workspace_id" => @workspace,
               "pane" => @agent_pane,
               "text" => "hi",
               "deliver_when" => "next_finished"
             })

    assert error == :invalid_deliver_when or match?(%{error: :invalid_deliver_when}, error)
  end

  test "an idle pane gets the message immediately rather than parking it", %{session: session} do
    AgentState.report(@workspace, session, @agent_pane, :idle, nil)

    assert {:ok, %{status: "delivered"}} = set_prompt("you are free, do this", nil)
    assert_receive {:delivered, _entry, :immediate}, 1_000
  end

  test "topology and agent_pane flag a pane with something staged" do
    {:ok, _} = set_prompt("waiting for you", "orch")

    assert {:ok, %{panes: panes}} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => @workspace,
               "session" => Tmux.session_name(@workspace, "main")
             })

    agent_pane = Enum.find(panes, &(&1.id == @agent_pane))
    assert agent_pane.pending_next_prompt == true
    assert agent_pane.pending_next_prompt_deliver_when == "next_idle"

    other = Enum.find(panes, &(&1.id == "%1"))
    refute Map.has_key?(other, :pending_next_prompt)

    assert {:ok, %{pending_next_prompt: true}} =
             TerminalTools.invoke("terminal_agent_pane", %{"workspace_id" => @workspace})
  end

  test "a staged message survives the pane going quiet and fires on done", %{session: session} do
    {:ok, _} = set_prompt("rebase first", "orch")

    AgentState.report(@workspace, session, @agent_pane, :working, nil)
    refute_receive {:delivered, _entry, _trigger}, 200

    AgentState.report(@workspace, session, @agent_pane, :done, nil)
    assert_receive {:delivered, entry, :done}, 1_000
    assert entry.text == "rebase first"
  end

  defp set_prompt(text, coalesce_key) do
    args =
      %{
        "workspace_id" => @workspace,
        "pane" => @agent_pane,
        "text" => text
      }
      |> then(fn args ->
        if coalesce_key, do: Map.put(args, "coalesce_key", coalesce_key), else: args
      end)

    TerminalTools.invoke("terminal_set_next_prompt", args)
  end
end
