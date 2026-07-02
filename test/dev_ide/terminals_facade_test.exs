defmodule DevIDE.TerminalsFacadeTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.Session.Info

  test "new_shell/3 and new_agent/2 build session info structs" do
    shell = Terminals.new_shell("ws-1", "u-dev")
    assert %Info{kind: :shell, workspace_id: "ws-1", sid: "u-dev"} = shell

    agent = Terminals.new_agent("agent-1", workspace_id: "ws-1")
    assert %Info{kind: :agent, workspace_id: "ws-1", id: "agent_agent-1"} = agent
  end

  test "attachment_policy/2 always resolves to raw mode" do
    info = Terminals.new_shell("ws-1", "u-dev")
    assert {:ok, :raw} = Terminals.attachment_policy(info, :raw)
  end

  test "owner_detach/2 is a no-op for dead owners" do
    pid = spawn(fn -> :timer.sleep(:infinity) end)
    Process.exit(pid, :kill)
    refute Process.alive?(pid)

    assert :ok = Terminals.owner_detach(pid, self())
  end

  test "owner_detach/2 tolerates orphaned owners after subscriber exit" do
    sid = "agent-#{System.unique_integer([:positive])}"
    info = Terminals.new_agent(sid, workspace_id: "ws-1")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-1", info, mode: :raw, session_id: sid)

    subscriber =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Process.exit(subscriber, :kill)
    assert :ok = Terminals.owner_detach(owner_pid, subscriber)
    assert :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "owner_input/2, owner_resize/3, owner_set_active/2, and owner_subscriber_count/1" do
    sid = "agent-#{System.unique_integer([:positive])}"
    info = Terminals.new_agent(sid, workspace_id: "ws-1")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-1", info, mode: :raw, session_id: sid)

    assert Terminals.owner_subscriber_count(owner_pid) == 1
    assert :ok = Terminals.owner_input(owner_pid, "ls\n")
    assert :ok = Terminals.owner_resize(owner_pid, 100, 30)
    assert :ok = Terminals.owner_set_active(owner_pid, true)
    assert :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "prepare_attachment/1 and resolve/1 build shell session info from sid" do
    assert {:ok, %Info{kind: :shell, sid: "u-dev"}} = Terminals.resolve("u-dev")
    assert {:ok, %Info{sid: "u-dev"}} = Terminals.prepare_attachment("u-dev")
    assert :error = Terminals.resolve(123)
  end

  test "tmux_session_in_workspace?/2 delegates workspace namespace checks" do
    workspace = %{id: "ws-1", name: "alpha"}

    assert Terminals.tmux_session_in_workspace?(Tmux.session_name("alpha", "u-dev"), workspace)
    assert Terminals.tmux_session_in_workspace?(Tmux.session_name("ws-1", "u-dev"), workspace)
    refute Terminals.tmux_session_in_workspace?(Tmux.session_name("other", "u-dev"), workspace)
  end
end
