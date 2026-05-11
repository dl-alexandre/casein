defmodule DevIdeWeb.TerminalChannelTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias DevIDE.Audit
  alias DevIDE.Runners
  alias DevIDE.Terminals.{Session, Tmux}
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  @endpoint DevIdeWeb.Endpoint

  setup do
    bypass = Bypass.open()
    workspace_root = Path.join(System.tmp_dir!(), "devide-terminal-channel")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_default = Application.get_env(:dev_ide, :default_workspace_mode)
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.delete_env(:dev_ide, :workspace_modes)

    MemoryAdapter.clear()
    Runners.clear()
    DevIDE.Runtimes.clear()
    Audit.clear()

    Bypass.stub(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runners.clear()
      DevIDE.Runtimes.clear()
      Audit.clear()
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
    end)

    {:ok, workspace_path: workspace_path}
  end

  test "governed terminal queues safe command assignments and exposes status" do
    {:ok, reply, socket} = join_terminal("governed")

    assert reply.mode == "governed"
    assert "mix test" in reply.commands
    assert Session.whereis("alpha", "tab-governed") == :error

    ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => "mix test"})
    assert_reply ref, :ok, %{status: "queued", assignment: assignment}

    assert assignment.safe_action_id == "command:test"
    assert assignment.action.argv == ["mix", "test", "--color"]
    assert {:ok, replay} = Runners.replay(assignment.id)
    assert replay.assignment.status == "queued"

    [event] = Audit.recent_for("ws-1", 5)
    assert event.action == "runner.assignment_queued"
    assert event.decision == :allow
    assert event.target_ref == "command:test"
  end

  test "governed terminal refuses unsafe commands without opening tmux" do
    {:ok, _reply, socket} = join_terminal("governed", "tab-denied")
    assert Session.whereis("alpha", "tab-denied") == :error

    ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => "rm -rf priv/"})
    assert_reply ref, :error, %{reason: "command is not a safe action"}

    assert Session.whereis("alpha", "tab-denied") == :error

    assert :none =
             Runners.poll(%{
               "protocol" => Runners.protocol(),
               "runner_id" => "runner-a",
               "capabilities" => ["workspace-command:v1"],
               "workspace_ids" => ["ws-1"]
             })

    [event] = Audit.recent_for("ws-1", 5)
    assert event.action == "policy.blocked"
    assert event.decision == :deny
    assert event.reason == :not_allowed
    assert event.target_type == "terminal_command"
    assert event.target_ref == "rm -rf priv/"
  end

  @tag :pty
  test "raw terminal joins only local manual workspaces and starts tmux PTY" do
    assert {:error, %{reason: "raw shell requires manual workspace mode"}} =
             join_terminal("raw", "raw-review")

    {:ok, _} = State.set_mode("ws-1", :manual)

    assert {:error, %{reason: "raw shell requires local host"}} =
             join_terminal("raw", "raw-remote", "remote")

    sid = "raw-local"
    tmux_session = Tmux.session_name("alpha", sid)

    on_exit(fn -> Tmux.kill(tmux_session) end)

    {:ok, reply, socket} = join_terminal("raw", sid)

    assert reply.mode == "raw"
    assert reply.cols > 0
    assert reply.rows > 0
    assert {:ok, pid} = Session.whereis("alpha", sid)
    assert socket.assigns.session_pid == pid
    assert Process.alive?(pid)

    Session.stop(pid)
  end

  defp join_terminal(mode, sid \\ "tab-governed", host_id \\ "local") do
    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
      "mode" => mode,
      "host_id" => host_id
    })
  end

  defp workspace_payload(conn, workspace_path) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => "alpha",
        "user" => "alice",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
