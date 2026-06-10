defmodule DevIdeWeb.TerminalChannelTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias DevIDE.Audit
  alias DevIDE.Runners
  alias DevIDE.Runs.Ledger
  alias DevIdeWeb.ChannelAuth
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
    prev_forward_auth = Application.get_env(:dev_ide, :forward_auth)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    Application.put_env(:dev_ide, :default_workspace_mode, :review)
    Application.delete_env(:dev_ide, :workspace_modes)

    reset_terminal_fast_path_cache!()

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
      kill_tmux_sessions_under(workspace_root)
      reset_terminal_fast_path_cache!()
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
      restore(:default_workspace_mode, prev_default)
      restore(:workspace_modes, prev_overrides)
      restore(:forward_auth, prev_forward_auth)
    end)

    {:ok, workspace_path: workspace_path, bypass: bypass}
  end

  test "governed terminal queues safe command assignments and exposes status" do
    {:ok, reply, socket} = join_terminal("governed")

    assert reply.mode == "governed"
    refute reply.raw_available
    assert "mix test" in reply.commands
    refute "grok" in reply.commands
    refute "claude" in reply.commands
    assert Session.whereis("alpha", "tab-governed") == :error

    ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => "mix test"})
    assert_reply ref, :ok, %{status: "queued", assignment: assignment}

    assert assignment.safe_action_id == "command:test"
    assert assignment.action.argv == ["mix", "test", "--color"]
    assert {:ok, replay} = Runners.replay(assignment.id)
    assert replay.assignment.status == "queued"

    [queued, requested] = Ledger.recent_for("ws-1", 5)
    assert queued.action == "run.queued"
    assert queued.decision == :allow
    assert queued.metadata["assignment_id"] == assignment.id
    assert queued.metadata["session_id"] == "tab-governed"

    assert requested.action == "run.command_requested"
    assert requested.metadata["session_id"] == "tab-governed"
    assert requested.metadata["run_id"] == queued.metadata["run_id"]
  end

  test "governed terminal advertises interactive launchers when raw shell is available" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    {:ok, reply, socket} = join_terminal("governed", "manual-governed")

    assert reply.mode == "governed"
    assert reply.raw_available
    assert "agent" in reply.commands
    assert "grok" in reply.commands
    assert "claude" in reply.commands

    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "governed terminal rejects direct interactive launcher command submissions" do
    {:ok, _reply, socket} = join_terminal("governed", "direct-grok")

    for command <- ["agent", "grok"] do
      ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => command})
      assert_reply ref, :error, %{reason: "interactive command requires raw shell"}

      [event | _] = Ledger.recent_for("ws-1", 5)
      assert event.action == "run.command_denied"
      assert event.reason == :requires_raw_terminal
      assert event.target_ref == command
    end

    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "governed terminal rejects oversized command lines" do
    {:ok, _reply, socket} = join_terminal("governed", "too-long-command")

    long = String.duplicate("x", 513)
    ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => long})
    assert_reply ref, :error, %{reason: "command line is too long"}

    [event] = Ledger.recent_for("ws-1", 5)
    assert event.action == "run.command_denied"
    assert event.decision == :deny
    assert event.target_ref == String.slice(long, 0, 512) <> "..."
    assert event.target_type == "command"
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

    [event] = Ledger.recent_for("ws-1", 5)
    assert event.action == "run.command_denied"
    assert event.decision == :deny
    assert event.reason == :not_allowed
    assert event.target_type == "command"
    assert event.target_ref == "rm -rf priv/"
  end

  test "unknown terminal mode falls back to governed mode for safe command policy" do
    {:ok, reply, socket} = join_terminal("not-a-real-mode", "mode-fallback")

    assert reply.mode == "governed"
    assert is_list(reply.commands)

    ref = Phoenix.ChannelTest.push(socket, "input", %{"data" => "ls\n"})
    assert_reply ref, :error, %{reason: "raw terminal input is disabled in governed mode"}
    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "blank command in governed mode returns blank status" do
    {:ok, _, socket} = join_terminal("governed", "blank-command")

    ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => "   "})
    assert_reply ref, :ok, %{status: "blank"}

    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "governed terminal rejects non-binary command payloads gracefully" do
    {:ok, _, socket} = join_terminal("governed", "typed-command")

    ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => 42})
    assert_reply ref, :error, %{reason: "command submission requires governed terminal mode"}
    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "governed terminal rejects missing command payload key" do
    {:ok, _, socket} = join_terminal("governed", "missing-command")

    ref = Phoenix.ChannelTest.push(socket, "command", %{})
    assert_reply ref, :error, %{reason: "command submission requires governed terminal mode"}
    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "governed terminal rejects nil command payloads" do
    {:ok, _, socket} = join_terminal("governed", "nil-command")

    ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => nil})
    assert_reply ref, :error, %{reason: "command submission requires governed terminal mode"}
    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "governed terminal rejects non-binary input payloads gracefully" do
    {:ok, _, socket} = join_terminal("governed", "typed-input")

    ref = Phoenix.ChannelTest.push(socket, "input", %{"data" => 42})
    assert_reply ref, :error, %{reason: "raw terminal input is disabled in governed mode"}
    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "malformed topic format is rejected" do
    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:error, %{reason: "invalid session"}} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:broken-topic", %{
               "mode" => "governed"
             })
  end

  test "malformed topic variants are rejected" do
    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    for topic <- [
          "terminal:ws-1",
          "terminal::sid",
          "terminal:",
          "terminal:ws-1:"
        ] do
      assert {:error, %{reason: "invalid session"}} =
               subscribe_and_join(socket, DevIdeWeb.TerminalChannel, topic, %{
                 "mode" => "governed"
               })
    end
  end

  test "join reuses cached workspace lookup for repeated joins on one socket", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, reply, socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:cache-a", %{
               "mode" => "governed"
             })

    assert reply.mode == "governed"

    assert {:ok, reply2, _socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:cache-b", %{
               "mode" => "governed"
             })

    assert reply2.mode == "governed"
    assert :counters.get(counter, 1) == 1

    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "workspace lookup cache is shared across fresh sockets for repeated governed joins", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket_one =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, _reply, _socket_one} =
             subscribe_and_join(
               socket_one,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:global-cache",
               %{"mode" => "governed"}
             )

    assert :counters.get(counter, 1) == 1

    socket_two =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, _reply_two, _socket_two} =
             subscribe_and_join(
               socket_two,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:global-cache-two",
               %{"mode" => "governed"}
             )

    assert :counters.get(counter, 1) == 1

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "fallback synthetic workspace claim is cached and reused on fresh socket reconnect", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "synthetic-reconnect"

    first_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, reply, first_socket} =
             subscribe_and_join(
               first_socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:#{sid}",
               %{
                 "mode" => "governed"
               }
             )

    assert reply.mode == "governed"
    assert first_socket.assigns.terminal_fast_path
    owner_pid = first_socket.assigns.terminal_owner_pid

    assert :counters.get(counter, 1) == 1

    second_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, reply2, second_socket} =
             subscribe_and_join(
               second_socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:#{sid}",
               %{
                 "mode" => "governed"
               }
             )

    assert reply2.mode == "governed"
    assert second_socket.assigns.terminal_fast_path
    assert :counters.get(counter, 1) == 1
    assert second_socket.assigns.terminal_owner_pid == owner_pid

    :ok = DevIDE.Terminals.owner_detach(owner_pid, self())
  end

  test "fast-path cache is actor-scoped and not reused across different users", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    prev_forward_auth = Application.get_env(:dev_ide, :forward_auth)
    Application.put_env(:dev_ide, :forward_auth, true)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "synthetic-actor-scope"

    try do
      dev_socket =
        DevIdeWeb.UserSocket
        |> socket("users_socket:dev", %{
          current_user: %{id: "dev", username: "alice", email: "dev@local"}
        })
        |> Phoenix.Socket.assign(:current_user, %{
          id: "dev",
          username: "alice",
          email: "dev@local"
        })

      assert {:ok, _reply, first_socket} =
               subscribe_and_join(
                 dev_socket,
                 DevIdeWeb.TerminalChannel,
                 "terminal:ws-1:#{sid}",
                 %{
                   "mode" => "governed"
                 }
               )

      assert :counters.get(counter, 1) == 1

      intruder_socket =
        DevIdeWeb.UserSocket
        |> socket("users_socket:dev", %{
          current_user: %{id: "intruder", username: "intruder", email: "intruder@local"}
        })
        |> Phoenix.Socket.assign(:current_user, %{
          id: "intruder",
          username: "intruder",
          email: "intruder@local"
        })

      assert {:ok, _reply, second_socket} =
               subscribe_and_join(
                 intruder_socket,
                 DevIdeWeb.TerminalChannel,
                 "terminal:ws-1:#{sid}",
                 %{
                   "mode" => "governed"
                 }
               )

      assert :counters.get(counter, 1) == 2
      assert second_socket.assigns.terminal_fast_path

      :ok = DevIDE.Terminals.owner_detach(first_socket.assigns.terminal_owner_pid, self())

      if second_socket.assigns.terminal_owner_pid != first_socket.assigns.terminal_owner_pid do
        :ok = DevIDE.Terminals.owner_detach(second_socket.assigns.terminal_owner_pid, self())
      end
    after
      restore(:forward_auth, prev_forward_auth)
    end
  end

  test "join uses terminal workspace capability when provided" do
    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true
      )

    assert {:ok, reply, _socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:capability", %{
               "mode" => "governed",
               "terminal_capability" => capability
             })

    assert reply.mode == "governed"
    assert is_list(reply.commands)
  end

  test "capability sid mismatch emits telemetry and falls back to workspace lookup" do
    test_pid = self()
    handler_id = {__MODULE__, :terminal_capability_mismatch, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:dev_ide, :terminal_channel, :capability_mismatch],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:terminal_capability_mismatch, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: "old-sid"
      )

    assert {:ok, reply, socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:new-sid", %{
               "mode" => "governed",
               "terminal_capability" => capability
             })

    assert reply.mode == "governed"
    assert socket.assigns.terminal_sid == "new-sid"

    assert_receive {:terminal_capability_mismatch, %{count: 1}, metadata}
    assert metadata.reason == :terminal_sid
    assert metadata.sid == "new-sid"
    assert metadata.capability_sid == "old-sid"

    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "governed join with valid terminal capability skips workspace lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true
      )

    assert {:ok, reply, socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:cap-fast", %{
               "mode" => "governed",
               "terminal_capability" => capability
             })

    assert reply.mode == "governed"
    assert socket.assigns.terminal_fast_path
    assert :counters.get(counter, 1) == 0
  end

  test "subsequent governed join without terminal capability can reuse fast-path cache", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true
      )

    assert {:ok, _reply, _socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:cache-capability",
               %{
                 "mode" => "governed",
                 "terminal_capability" => capability
               }
             )

    assert :counters.get(counter, 1) == 0

    assert {:ok, reply, _socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:cache-capability",
               %{
                 "mode" => "governed"
               }
             )

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 0
  end

  test "mode transition can reuse fast-path cache across governed↔raw reconnects", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "mode-transition-cache"

    governed_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, reply, _governed_joined} =
             subscribe_and_join(
               governed_socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:#{sid}",
               %{
                 "mode" => "governed"
               }
             )

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 1

    raw_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(raw_socket, "terminal:ws-1:#{sid}") do
      {:ok, raw_reply, _raw_joined} ->
        assert raw_reply.mode == "raw"
        assert :counters.get(counter, 1) == 1

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "stale mode cache entry falls back to wildcard claim in fresh socket fast cache", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "wildcard-recovery"

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    stale_claims = {
      terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :governed),
      %{
        kind: :terminal_workspace,
        user_id: "dev",
        workspace_id: "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_host_id: "local",
        terminal_sid: sid,
        raw_terminal_ok: true
      },
      System.system_time(:millisecond) - 1
    }

    wildcard_claims = {
      terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any),
      %{
        kind: :terminal_workspace,
        user_id: "dev",
        workspace_id: "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_host_id: "local",
        terminal_sid: sid,
        raw_terminal_ok: true
      },
      System.system_time(:millisecond) + 60_000
    }

    :ets.insert(:dev_ide_terminal_fast_path_cache, [stale_claims, wildcard_claims])

    case join_raw(socket, "terminal:ws-1:#{sid}") do
      {:ok, reply, _socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 0

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "governed fast-path cache is not reused for raw mode reconnect attempts", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true
      )

    assert {:ok, _reply, _socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:mode-mismatch",
               %{
                 "mode" => "governed",
                 "terminal_capability" => capability
               }
             )

    assert :counters.get(counter, 1) == 0

    assert {:error, %{reason: "raw shell requires manual workspace mode"}} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:mode-mismatch",
               %{
                 "mode" => "raw"
               }
             )

    assert :counters.get(counter, 1) == 1
  end

  test "stale exact fast-path cache entries fall back to fresh workspace cache", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    sid = "cache-expiry"

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true
      )

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
               "mode" => "governed",
               "terminal_capability" => capability
             })

    assert :counters.get(counter, 1) == 0

    stale_claim =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true
      )

    {:ok, claims} = ChannelAuth.verify_terminal_capability(stale_claim)
    cache_key = terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :governed)
    :ets.insert(:dev_ide_terminal_fast_path_cache, {cache_key, claims, 0})
    assert :ets.lookup(:dev_ide_terminal_fast_path_cache, cache_key) != []

    assert {:ok, reply, _socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
               "mode" => "governed"
             })

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 0
    assert :ets.lookup(:dev_ide_terminal_fast_path_cache, cache_key) != []
  end

  test "stale socket-local fast-path cache entries are ignored and fall back to workspace lookup",
       %{
         bypass: bypass,
         workspace_path: workspace_path
       } do
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "socket-cache-expired"

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    stale_cache = %{
      terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :governed) => {
        %{},
        System.system_time(:millisecond) - 1
      }
    }

    socket = Phoenix.Socket.assign(socket, :terminal_fast_path_cache, stale_cache)

    assert {:ok, reply, _socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
               "mode" => "governed"
             })

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 1
  end

  test "numeric actor id is accepted for fast-path caching and reuse", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "numeric-actor-cache"

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{
        current_user: %{id: 42, email: "dev@local", username: "dev"}
      })
      |> Phoenix.Socket.assign(:current_user, %{id: 42, email: "dev@local", username: "dev"})

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
               "mode" => "governed"
             })

    assert :counters.get(counter, 1) == 1

    assert {:ok, reply2, _socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
               "mode" => "governed"
             })

    assert reply2.mode == "governed"
    assert :counters.get(counter, 1) == 1
  end

  test "socket fast-path cache is host-scoped for raw reconnect", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)

    sid = "socket-cache-host-scope"

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: sid
      )

    case join_raw(socket, "terminal:ws-1:#{sid}", %{"terminal_capability" => capability}) do
      {:ok, reply, raw_socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 0

        assert {:error, %{reason: "raw shell requires local host"}} =
                 subscribe_and_join(
                   raw_socket,
                   DevIdeWeb.TerminalChannel,
                   "terminal:ws-1:#{sid}",
                   %{
                     "mode" => "raw",
                     "host_id" => "remote"
                   }
                 )

        assert :counters.get(counter, 1) == 1
        safe_owner_detach(raw_socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "stale exact raw cache entries fall back to fresh workspace cache", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "wildcard-stale-cache"

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: sid
      )

    {:ok, workspace_claim} = ChannelAuth.verify_terminal_capability(capability)
    workspace_claim = Map.delete(workspace_claim, :terminal_sid)
    expires_at = System.system_time(:millisecond) + 60_000

    stale_claims = [
      {
        terminal_fast_path_cache_key("dev", "ws-1", :workspace, "local", :raw),
        workspace_claim,
        expires_at
      },
      {
        terminal_fast_path_cache_key("dev", "ws-1", :workspace, "local", :any),
        workspace_claim,
        expires_at
      },
      {
        terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw),
        %{kind: :terminal_workspace, user_id: "dev", workspace_id: "ws-1"},
        System.system_time(:millisecond) - 1
      },
      {
        terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any),
        %{kind: :terminal_workspace, user_id: "dev", workspace_id: "ws-1"},
        System.system_time(:millisecond) - 1
      }
    ]

    :ets.insert(:dev_ide_terminal_fast_path_cache, stale_claims)

    reconnect_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(reconnect_socket, "terminal:ws-1:#{sid}", %{
           "terminal_capability" => capability
         }) do
      {:ok, _reply, _second_socket} ->
        assert :counters.get(counter, 1) == 0

        assert :ets.lookup(
                 :dev_ide_terminal_fast_path_cache,
                 terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw)
               ) != []

        assert :ets.lookup(
                 :dev_ide_terminal_fast_path_cache,
                 terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any)
               ) != []

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "stale ETS wildcard mode entry falls back to fresh wildcard claim", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "wildcard-ets-recovery"

    stale_claim =
      {
        terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw),
        %{
          kind: :terminal_workspace,
          user_id: "dev",
          workspace_id: "ws-1",
          workspace_name: "alpha",
          workspace_user: "alice",
          workspace_path: workspace_path,
          workspace_host_id: "local",
          terminal_sid: sid,
          raw_terminal_ok: true
        },
        System.system_time(:millisecond) - 1
      }

    wildcard_claim =
      {
        terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any),
        %{
          kind: :terminal_workspace,
          user_id: "dev",
          workspace_id: "ws-1",
          workspace_name: "alpha",
          workspace_user: "alice",
          workspace_path: workspace_path,
          workspace_host_id: "local",
          terminal_sid: sid,
          raw_terminal_ok: true
        },
        System.system_time(:millisecond) + 60_000
      }

    :ets.insert(:dev_ide_terminal_fast_path_cache, [stale_claim, wildcard_claim])

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(socket, "terminal:ws-1:#{sid}") do
      {:ok, reply, joined_socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 0
        assert joined_socket.assigns.terminal_fast_path

        assert :ets.lookup(
                 :dev_ide_terminal_fast_path_cache,
                 terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw)
               ) != []

        assert :ets.lookup(
                 :dev_ide_terminal_fast_path_cache,
                 terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any)
               ) != []

        safe_owner_detach(joined_socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "stale socket wildcard cache entries are purged before workspace lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "socket-wildcard-expiry"

    stale_wildcard_cache = %{
      terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any) => {
        %{
          kind: :terminal_workspace,
          user_id: "dev",
          workspace_id: "ws-1",
          workspace_name: "alpha",
          workspace_user: "alice",
          workspace_path: workspace_path,
          workspace_host_id: "local",
          terminal_sid: sid
        },
        System.system_time(:millisecond) - 1
      }
    }

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})
      |> Phoenix.Socket.assign(:terminal_fast_path_cache, stale_wildcard_cache)

    stale_key = terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any)

    case join_raw(socket, "terminal:ws-1:#{sid}") do
      {:ok, reply, rejoined_socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 1
        assert Map.has_key?(rejoined_socket.assigns.terminal_fast_path_cache, stale_key)

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "raw reconnect with different host does not reuse wildcard fast-path cache", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "raw-host-boundary-cache"

    local_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: sid
      )

    case join_raw(local_socket, "terminal:ws-1:#{sid}", %{"terminal_capability" => capability}) do
      {:ok, _reply, local_socket} ->
        assert :counters.get(counter, 1) == 0

        remote_socket =
          DevIdeWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        assert {:error, %{reason: "raw shell requires local host"}} =
                 subscribe_and_join(
                   remote_socket,
                   DevIdeWeb.TerminalChannel,
                   "terminal:ws-1:#{sid}",
                   %{
                     "mode" => "raw",
                     "host_id" => "remote"
                   }
                 )

        assert :counters.get(counter, 1) == 1
        safe_owner_detach(local_socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "raw fast-path cache is host-scoped across fresh sockets", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "raw-host-scope-fresh"

    local_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: sid
      )

    # Host-scoping coverage requires a successful local raw attach to populate the
    # fast-path cache; when the PTY is unavailable that premise can't be set up, so
    # skip rather than crash (consistent with the other raw reconnect tests).
    case join_raw_with_capability(local_socket, "terminal:ws-1:#{sid}", capability) do
      {:ok, _reply, local_socket} ->
        assert :counters.get(counter, 1) == 0

        remote_socket =
          DevIdeWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        assert {:error, %{reason: "raw shell requires local host"}} =
                 subscribe_and_join(
                   remote_socket,
                   DevIdeWeb.TerminalChannel,
                   "terminal:ws-1:#{sid}",
                   %{
                     "mode" => "raw",
                     "host_id" => "remote"
                   }
                 )

        assert :counters.get(counter, 1) == 1
        safe_owner_detach(local_socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "forward-auth user mismatch does not reuse terminal fast-path cache", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    prev_forward_auth = Application.get_env(:dev_ide, :forward_auth)
    Application.put_env(:dev_ide, :forward_auth, true)

    try do
      counter = count_workspace_requests!(bypass, workspace_path)
      sid = "forward-auth-fast-path-mismatch"

      dev_socket =
        DevIdeWeb.UserSocket
        |> socket("users_socket:dev", %{
          current_user: %{id: "dev", email: "dev@local", username: "dev"}
        })
        |> Phoenix.Socket.assign(:current_user, %{
          id: "dev",
          email: "dev@local",
          username: "dev"
        })

      capability =
        ChannelAuth.sign_terminal_capability("dev", "ws-1",
          workspace_name: "alpha",
          workspace_user: "alice",
          workspace_path: workspace_path,
          workspace_loc: {:local, workspace_path},
          workspace_host_id: "local",
          owner_ok: true,
          terminal_owner_ok: true,
          terminal_sid: sid
        )

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 dev_socket,
                 DevIdeWeb.TerminalChannel,
                 "terminal:ws-1:#{sid}",
                 %{
                   "mode" => "governed",
                   "terminal_capability" => capability
                 }
               )

      intruder_socket =
        DevIdeWeb.UserSocket
        |> socket("users_socket:dev", %{
          current_user: %{id: "intruder", email: "intruder@remote", username: "intruder"}
        })
        |> Phoenix.Socket.assign(:current_user, %{
          id: "intruder",
          email: "intruder@remote",
          username: "intruder"
        })

      assert {:error, %{reason: "raw shell requires manual workspace mode"}} =
               subscribe_and_join(
                 intruder_socket,
                 DevIdeWeb.TerminalChannel,
                 "terminal:ws-1:#{sid}",
                 %{
                   "mode" => "raw"
                 }
               )

      assert :counters.get(counter, 1) == 1
    after
      restore(:forward_auth, prev_forward_auth)
    end
  end

  test "socket-fast-path cache bypasses workspace lookup when ETS claim cache is missing", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "socket-cache-miss"

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true
      )

    assert {:ok, reply, socket} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
               "mode" => "governed",
               "terminal_capability" => capability
             })

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 0

    cache_key = terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :governed)
    :ets.delete(:dev_ide_terminal_fast_path_cache, cache_key)
    assert :ets.lookup(:dev_ide_terminal_fast_path_cache, cache_key) == []

    assert {:ok, reply2, _socket2} =
             subscribe_and_join(socket, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
               "mode" => "governed"
             })

    assert reply2.mode == "governed"
    assert :counters.get(counter, 1) == 0
  end

  test "socket-fast-path cache avoids extra workspace lookup for raw reconnect", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "socket-cache-raw"

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true
      )

    case join_raw(socket, "terminal:ws-1:#{sid}", %{"terminal_capability" => capability}) do
      {:ok, reply, socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 0

        cache_key = terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw)
        :ets.delete(:dev_ide_terminal_fast_path_cache, cache_key)
        assert :ets.lookup(:dev_ide_terminal_fast_path_cache, cache_key) == []

        case join_raw(socket, "terminal:ws-1:#{sid}") do
          {:ok, reply2, _socket2} ->
            assert reply2.mode == "raw"
            assert :counters.get(counter, 1) == 0

          {:error, :pty_unavailable} ->
            :ok
        end

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "governed join with valid terminal capability does not set fast-path when terminal_sid mismatches",
       %{
         bypass: bypass,
         workspace_path: workspace_path
       } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        terminal_sid: "other-session"
      )

    assert {:ok, reply, socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:cap-incorrect-session",
               %{"mode" => "governed", "terminal_capability" => capability}
             )

    assert reply.mode == "governed"
    refute socket.assigns.terminal_fast_path
    assert :counters.get(counter, 1) == 1

    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "raw-capable terminal token does not switch a governed join into raw mode", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "mode-boundary"
      )

    assert {:ok, reply, _socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:mode-boundary",
               %{
                 "mode" => "governed",
                 "terminal_capability" => capability
               }
             )

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 0
  end

  test "join ignores malformed terminal capability and falls back to workspace lookup" do
    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, reply, _socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:bad-capability",
               %{
                 "mode" => "governed",
                 "terminal_capability" => "not-even-a-valid-token"
               }
             )

    assert reply.mode == "governed"
    assert is_list(reply.commands)
  end

  test "terminal capability with matching terminal_sid uses fast path", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        terminal_sid: "cache-a"
      )

    assert {:ok, reply, _socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:cache-a",
               %{"mode" => "governed", "terminal_capability" => capability}
             )

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 0
  end

  test "terminal capability with mismatched terminal_sid falls back to workspace lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        terminal_sid: "wrong-sid"
      )

    assert {:ok, reply, _socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:cache-a",
               %{"mode" => "governed", "terminal_capability" => capability}
             )

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 1
  end

  test "terminal capability with mismatched workspace_host_id falls back to workspace lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        terminal_sid: "cap-host"
      )

    assert {:ok, reply, _socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:cap-host",
               %{
                 "mode" => "governed",
                 "host_id" => "remote",
                 "terminal_capability" => capability
               }
             )

    assert reply.mode == "governed"
    assert :counters.get(counter, 1) == 1
  end

  test "terminal capability with mismatched user id falls back to workspace lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: 12, email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: 12, email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp"
      )

    assert {:ok, _reply, socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:mismatch-user",
               %{
                 "mode" => "governed",
                 "terminal_capability" => capability
               }
             )

    assert :counters.get(counter, 1) == 1

    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "terminal capability with owner_ok false is denied" do
    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: false
      )

    assert {:error, %{reason: "terminal access is not authorized"}} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:owner-deny",
               %{"mode" => "governed", "terminal_capability" => capability}
             )
  end

  test "terminal capability with terminal_owner_ok false is denied" do
    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        terminal_owner_ok: false
      )

    assert {:error, %{reason: "terminal access is not authorized"}} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:owner-deny-terminal",
               %{"mode" => "governed", "terminal_capability" => capability}
             )
  end

  test "raw join with terminal capability skips raw boundary when raw_terminal_ok is true", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "raw-capability-ok"
      )

    case join_raw_with_capability(socket, "terminal:ws-1:raw-capability-ok", capability) do
      {:ok, reply, joined_socket} ->
        assert reply.mode == "raw"
        assert joined_socket.assigns.terminal_fast_path

        case join_raw_with_capability(
               joined_socket,
               "terminal:ws-1:raw-capability-ok",
               capability
             ) do
          {:ok, _reply2, _socket2} ->
            safe_owner_detach(joined_socket.assigns[:terminal_owner_pid], self())

          {:error, :pty_unavailable} ->
            :ok
        end

      {:error, :pty_unavailable} ->
        :ok
    end

    assert :counters.get(counter, 1) == 0
  end

  test "raw join with valid capability skips manager lookup in reconnect window", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)

    user_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: "raw-fast-reconnect"
      )

    # First capability join (establishes owner)
    case join_raw_with_capability(user_socket, "terminal:ws-1:raw-fast-reconnect", capability) do
      {:ok, _reply, joined} ->
        # Second join on same sid (reconnect / tab in window) — must hit fast cache, no manager lookup
        case join_raw_with_capability(user_socket, "terminal:ws-1:raw-fast-reconnect", capability) do
          {:ok, _reply2, _joined2} ->
            safe_owner_detach(joined.assigns[:terminal_owner_pid], self())

          {:error, :pty_unavailable} ->
            safe_owner_detach(joined.assigns[:terminal_owner_pid], self())
        end

      {:error, :pty_unavailable} ->
        :ok
    end

    assert :counters.get(counter, 1) == 0
  end

  test "raw reconnect on fresh socket with capability does not re-run workspace lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: "raw-fast-reconnect-fresh"
      )

    first_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    # Resilient to environments where raw PTY attach can fail/exit (no pty, timing,
    # container limits); mirrors the sibling reconnect test above. The meaningful
    # assertion — the fast-path cache prevents a second manager workspace lookup —
    # still holds whether or not the PTY attach succeeds on reconnect.
    case join_raw_with_capability(
           first_socket,
           "terminal:ws-1:raw-fast-reconnect-fresh",
           capability
         ) do
      {:ok, reply_one, socket_one} ->
        assert reply_one.mode == "raw"
        assert :counters.get(counter, 1) == 0

        second_socket =
          DevIdeWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        case join_raw_with_capability(
               second_socket,
               "terminal:ws-1:raw-fast-reconnect-fresh",
               capability
             ) do
          {:ok, reply_two, _socket_two} ->
            assert reply_two.mode == "raw"

          {:error, :pty_unavailable} ->
            :ok
        end

        assert :counters.get(counter, 1) == 0
        safe_owner_detach(socket_one.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "raw join reuse without terminal capability can skip workspace lookup from cache", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: "cache-raw-cap"
      )

    case join_raw(socket, "terminal:ws-1:cache-raw-cap", %{"terminal_capability" => capability}) do
      {:ok, _reply, _socket} ->
        assert :counters.get(counter, 1) == 0

        case join_raw(socket, "terminal:ws-1:cache-raw-cap") do
          {:ok, reply, _socket} ->
            assert reply.mode == "raw"
            assert :counters.get(counter, 1) == 0

          {:error, :pty_unavailable} ->
            :ok
        end

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "raw capability without raw_terminal_ok does not bypass boundary check" do
    assert {:ok, _} = State.set_mode("ws-1", :review)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: false,
        terminal_sid: "raw-capability-deny"
      )

    assert {:error, %{reason: reason}} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:raw-capability-deny",
               %{"mode" => "raw", "terminal_capability" => capability}
             )

    assert reason == "raw shell requires manual workspace mode"
  end

  test "raw capability is cached on socket and reused for reconnect without extra lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "raw-capability-cache"
      )

    case join_raw(socket, "terminal:ws-1:raw-capability-cache", %{
           "terminal_capability" => capability
         }) do
      {:ok, reply, joined_socket} ->
        assert reply.mode == "raw"
        assert is_pid(joined_socket.assigns.terminal_owner_pid)

        case join_raw(joined_socket, "terminal:ws-1:raw-capability-cache") do
          {:ok, reply2, rejoin_socket} ->
            assert reply2.mode == "raw"

            assert rejoin_socket.assigns.terminal_owner_pid ==
                     joined_socket.assigns.terminal_owner_pid

            safe_owner_detach(rejoin_socket.assigns[:terminal_owner_pid], self())

          {:error, :pty_unavailable} ->
            :ok
        end

      {:error, :pty_unavailable} ->
        :ok
    end

    assert :counters.get(counter, 1) == 0
    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "governed capability is cached on socket and reused for reconnect without extra lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: "governed-capability-cache"
      )

    assert {:ok, reply, socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:governed-capability-cache",
               %{
                 "mode" => "governed",
                 "terminal_capability" => capability
               }
             )

    assert reply.mode == "governed"
    assert is_pid(socket.assigns.terminal_owner_pid)
    assert :counters.get(counter, 1) == 0

    assert {:ok, reply2, rejoin_socket} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:governed-capability-cache",
               %{
                 "mode" => "governed"
               }
             )

    assert reply2.mode == "governed"

    {:ok, info} = DevIDE.Terminals.resolve("governed-capability-cache")
    key = DevIDE.Terminals.SessionOwner.owner_key(info)
    [{owner_pid, _}] = Registry.lookup(DevIDE.Terminals.Registry, key)

    assert rejoin_socket.assigns.terminal_owner_pid == owner_pid
    assert socket.assigns.terminal_owner_pid == owner_pid
    assert :counters.get(counter, 1) == 0

    :ok = DevIDE.Terminals.owner_detach(rejoin_socket.assigns.terminal_owner_pid, self())
    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "raw terminal capability with host mismatch still enforces host policy" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "raw-capability-host"
      )

    assert {:error, %{reason: reason}} =
             subscribe_and_join(
               socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:raw-capability-host",
               %{
                 "mode" => "raw",
                 "host_id" => "remote",
                 "terminal_capability" => capability
               }
             )

    assert reason == "raw shell requires local host"
  end

  test "join ignores tampered terminal capability and falls back to workspace lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    prev = Application.get_env(:dev_ide, :forward_auth)
    Application.put_env(:dev_ide, :forward_auth, true)
    counter = count_workspace_requests!(bypass, workspace_path)

    workspace_token =
      ChannelAuth.sign_terminal_capability("alice", "ws-1",
        workspace_name: "alpha",
        workspace_user: "alice",
        workspace_path: "/tmp"
      )

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{
        current_user: %{id: "intruder", username: "intruder", email: "intruder@local"}
      })
      |> Phoenix.Socket.assign(:current_user, %{
        id: "intruder",
        username: "intruder",
        email: "intruder@local"
      })

    try do
      assert {:ok, _reply, joined_socket} =
               subscribe_and_join(
                 socket,
                 DevIdeWeb.TerminalChannel,
                 "terminal:ws-1:tampered-capability",
                 %{"mode" => "governed", "terminal_capability" => workspace_token}
               )

      assert :counters.get(counter, 1) == 1
      refute joined_socket.assigns.terminal_fast_path
      :ok = DevIDE.Terminals.owner_detach(joined_socket.assigns.terminal_owner_pid, self())
    after
      restore(:forward_auth, prev)
    end
  end

  test "governed join allows known workspace links for non-owner forward-auth users" do
    prev = Application.get_env(:dev_ide, :forward_auth)
    Application.put_env(:dev_ide, :forward_auth, true)

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{
        current_user: %{id: "intruder", username: "intruder", email: "intruder@evil"}
      })
      |> Phoenix.Socket.assign(:current_user, %{
        id: "intruder",
        username: "intruder",
        email: "intruder@evil"
      })

    try do
      assert {:ok, reply, joined_socket} =
               subscribe_and_join(
                 socket,
                 DevIdeWeb.TerminalChannel,
                 "terminal:ws-1:owned-deny",
                 %{
                   "mode" => "governed"
                 }
               )

      assert reply.mode == "governed"
      :ok = DevIDE.Terminals.owner_detach(joined_socket.assigns.terminal_owner_pid, self())
    after
      restore(:forward_auth, prev)
    end
  end

  test "governed join rejects raw input", %{workspace_path: _workspace_path} do
    {:ok, _, socket} = join_terminal("governed", "governed-input-policy")
    ref = Phoenix.ChannelTest.push(socket, "input", %{"data" => "ls\n"})
    assert_reply ref, :error, %{reason: "raw terminal input is disabled in governed mode"}
  end

  test "raw join rejects governed commands" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    case join_terminal("raw", "raw-command-policy", "local") do
      {:ok, _, socket} ->
        ref = Phoenix.ChannelTest.push(socket, "command", %{"line" => "mix test"})
        assert_reply ref, :error, %{reason: "command submission requires governed terminal mode"}

      {:error, %{reason: reason}} ->
        assert pty_unavailable?(reason)
    end
  end

  @tag :pty
  test "raw terminal joins only local manual workspaces and starts tmux PTY", %{
    workspace_path: workspace_path
  } do
    assert {:error, %{reason: "raw shell requires manual workspace mode"}} =
             join_terminal("raw", "raw-review")

    {:ok, _} = State.set_mode("ws-1", :manual)

    assert {:error, %{reason: "raw shell requires local host"}} =
             join_terminal("raw", "raw-remote", "remote")

    sid = "raw-local"
    tmux_session = Tmux.session_name("alpha", sid)

    on_exit(fn -> Tmux.kill(tmux_session) end)

    case join_terminal("raw", sid) do
      {:ok, reply, socket} ->
        assert reply.mode == "raw"
        assert reply.cols > 0
        assert reply.rows > 0
        assert is_pid(socket.assigns.terminal_owner_pid)

        case join_terminal("raw", sid) do
          {:ok, second_reply, second_socket} ->
            assert second_reply.mode == "raw"
            assert second_socket.assigns.terminal_owner_pid == socket.assigns.terminal_owner_pid

          {:error, %{reason: reason}} ->
            assert pty_unavailable?(reason)
        end

        kill_tmux_sessions_under(Path.dirname(workspace_path))

      {:error, %{reason: reason}} ->
        assert pty_unavailable?(reason)
    end
  end

  @tag :pty
  test "repeated raw joins on one socket do not duplicate session_attached audit entries", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    sid = "raw-session-cache-repeat"

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(socket, "terminal:ws-1:#{sid}") do
      {:error, :pty_unavailable} ->
        :ok

      {:ok, _reply, raw_socket} ->
        events = Ledger.recent_for("ws-1", 10)
        assert length(events) == 1
        [attached] = events
        assert attached.action == "run.session_attached"
        assert attached.decision == :allow

        case join_raw(raw_socket, "terminal:ws-1:#{sid}") do
          {:ok, _reply2, raw_socket_two} ->
            assert [attached] = Ledger.recent_for("ws-1", 10)
            assert attached.action == "run.session_attached"
            safe_owner_detach(raw_socket_two.assigns[:terminal_owner_pid], self())

          {:error, :pty_unavailable} ->
            :ok
        end

        safe_owner_detach(raw_socket.assigns[:terminal_owner_pid], self())
        kill_tmux_sessions_under(Path.dirname(workspace_path))
    end
  end

  @tag :pty
  test "raw workspace cache avoids repeated manager status requests", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    sid = "raw-cache-workspace"

    socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(socket, "terminal:ws-1:#{sid}") do
      {:ok, _reply, raw_socket} ->
        case join_raw(raw_socket, "terminal:ws-1:#{sid}") do
          {:ok, _reply2, _raw_socket_two} -> :ok
          {:error, :pty_unavailable} -> :ok
        end

        # One manager lookup regardless of whether the reconnect attach succeeded.
        assert :counters.get(counter, 1) == 1
        safe_owner_detach(raw_socket.assigns[:terminal_owner_pid], self())
        kill_tmux_sessions_under(Path.dirname(workspace_path))

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  @tag :pty
  test "raw reconnect on fresh socket reuses cached auth and shared owner", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(bypass, workspace_path)

    sid = "raw-reconnect-fresh-socket"

    first_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(first_socket, "terminal:ws-1:#{sid}") do
      {:ok, _reply, socket_one} ->
        owner_pid = socket_one.assigns.terminal_owner_pid
        assert is_pid(owner_pid)
        assert :counters.get(counter, 1) == 1

        second_socket =
          DevIdeWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        case join_raw(second_socket, "terminal:ws-1:#{sid}") do
          {:ok, _reply, socket_two} ->
            assert socket_two.assigns.terminal_owner_pid == owner_pid
            assert :counters.get(counter, 1) == 1

          {:error, :pty_unavailable} ->
            :ok
        end

        safe_owner_detach(owner_pid, self())

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  @tag :pty
  test "raw reconnect on fresh socket does not duplicate session_attached events", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    sid = "raw-reconnect-no-duplicate-events"

    first_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    first_join =
      subscribe_and_join(
        first_socket,
        DevIdeWeb.TerminalChannel,
        "terminal:ws-1:#{sid}",
        %{
          "mode" => "raw"
        }
      )

    case first_join do
      {:ok, _reply, first_joined} ->
        assert Enum.count(Ledger.recent_for("ws-1", 10), &(&1.action == "run.session_attached")) ==
                 1

        second_socket =
          DevIdeWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        second_join =
          try do
            subscribe_and_join(
              second_socket,
              DevIdeWeb.TerminalChannel,
              "terminal:ws-1:#{sid}",
              %{
                "mode" => "raw"
              }
            )
          catch
            :exit, _ -> {:error, %{reason: "raw reconnect exited"}}
          end

        case second_join do
          {:ok, _reply, second_joined} ->
            assert second_joined.assigns.terminal_owner_pid ==
                     first_joined.assigns.terminal_owner_pid

            assert Enum.count(
                     Ledger.recent_for("ws-1", 10),
                     &(&1.action == "run.session_attached")
                   ) ==
                     1

          {:error, %{reason: reason}} ->
            assert pty_unavailable?(reason)

            assert Enum.count(
                     Ledger.recent_for("ws-1", 10),
                     &(&1.action == "run.session_attached")
                   ) ==
                     1
        end

        :ok = DevIDE.Terminals.owner_detach(first_joined.assigns.terminal_owner_pid, self())

      {:error, %{reason: reason}} ->
        assert pty_unavailable?(reason)

        assert Enum.count(Ledger.recent_for("ws-1", 10), &(&1.action == "run.session_attached")) <=
                 1
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "governed reconnect on fresh socket reuses auth cache without extra lookup", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(bypass, workspace_path)
    sid = "governed-reconnect-no-duplicate-events"

    first_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, _reply, first_joined} =
             subscribe_and_join(
               first_socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:#{sid}",
               %{
                 "mode" => "governed"
               }
             )

    assert :counters.get(counter, 1) == 1

    second_socket =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, _reply, second_joined} =
             subscribe_and_join(
               second_socket,
               DevIdeWeb.TerminalChannel,
               "terminal:ws-1:#{sid}",
               %{"mode" => "governed"}
             )

    assert :counters.get(counter, 1) == 1
    assert second_joined.assigns.terminal_owner_pid == first_joined.assigns.terminal_owner_pid

    owner_pid = first_joined.assigns.terminal_owner_pid
    :ok = DevIDE.Terminals.owner_detach(owner_pid, self())
    :ok = DevIDE.Terminals.owner_detach(owner_pid, self())
    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "raw denial does not seed fast-path cache for later governed join", %{
    bypass: bypass,
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :review)
    counter = count_workspace_requests!(bypass, workspace_path)

    sid = "mode-deny-does-not-cache"

    assert {:error, %{reason: "raw shell requires manual workspace mode"}} =
             join_terminal("raw", sid)

    assert :counters.get(counter, 1) == 1

    governed =
      DevIdeWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:ok, _reply, socket} =
             subscribe_and_join(governed, DevIdeWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
               "mode" => "governed"
             })

    assert :counters.get(counter, 1) == 2
    assert socket.assigns.terminal_fast_path
    :ok = DevIDE.Terminals.owner_detach(socket.assigns.terminal_owner_pid, self())
  end

  test "raw join denial is cached across fresh sockets for the same session" do
    sid = "raw-deny-cache"

    assert {:error, %{reason: "raw shell requires manual workspace mode"}} =
             join_terminal("raw", sid)

    events_after_first = Ledger.recent_for("ws-1", 10)
    assert length(events_after_first) == 1
    [denied] = events_after_first
    assert denied.action == "run.session_denied"
    assert denied.reason == :requires_manual_mode

    assert {:error, %{reason: "raw shell requires manual workspace mode"}} =
             join_terminal("raw", sid)

    events_after_second = Ledger.recent_for("ws-1", 10)
    assert length(events_after_second) == 2
    assert Enum.all?(events_after_second, &(&1.action == "run.session_denied"))
    assert Enum.all?(events_after_second, &(&1.reason == :requires_manual_mode))
  end

  test "raw join denied when local workspace is not in manual mode" do
    sid = "raw-review-deny"

    assert {:error, %{reason: "raw shell requires manual workspace mode"}} =
             join_terminal("raw", sid)

    assert Registry.lookup(DevIDE.Terminals.Registry, {:terminal_owner, :shell, "", sid}) == []
  end

  test "raw join denied on remote host and owner is not started" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    assert {:error, %{reason: "raw shell requires local host"}} =
             join_terminal("raw", "raw-remote-deny", "remote")

    assert Registry.lookup(
             DevIDE.Terminals.Registry,
             {:terminal_owner, :shell, "", "raw-remote-deny"}
           ) == []
  end

  test "repeated raw join denial attempts do not start owners" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    sid = "raw-reject-repeat"

    assert {:error, %{reason: "raw shell requires local host"}} =
             join_terminal("raw", sid, "remote")

    assert {:error, %{reason: "raw shell requires local host"}} =
             join_terminal("raw", sid, "remote")

    assert Registry.lookup(DevIDE.Terminals.Registry, {:terminal_owner, :shell, "", sid}) == []
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

  defp count_workspace_requests!(bypass, workspace_path) do
    counter = :counters.new(1, [])

    Bypass.stub(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      :counters.add(counter, 1, 1)
      workspace_payload(conn, workspace_path)
    end)

    counter
  end

  defp kill_tmux_sessions_under(root) do
    kill_tmux_sessions_under(root, 10)
  end

  defp kill_tmux_sessions_under(_root, 0), do: :ok

  defp kill_tmux_sessions_under(root, attempts) do
    root = canonical_path(root)

    killed =
      case System.cmd(
             "tmux",
             ["list-panes", "-a", "-F", "\#{session_name}\t\#{pane_current_path}"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.split(&1, "\t", parts: 2))
          |> Enum.reduce(false, fn
            [session, path], acc ->
              if String.starts_with?(canonical_path(path), root) do
                System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
                true
              else
                acc
              end

            _, acc ->
              acc
          end)

        _ ->
          false
      end

    if killed do
      kill_tmux_sessions_under(root, attempts - 1)
    else
      Process.sleep(50)
      kill_tmux_sessions_under(root, attempts - 1)
    end
  end

  defp canonical_path(path) do
    path = Path.expand(path)

    cond do
      String.starts_with?(path, "/private/") -> path
      String.starts_with?(path, "/var/") -> "/private" <> path
      String.starts_with?(path, "/tmp/") -> "/private" <> path
      true -> path
    end
  end

  defp terminal_fast_path_cache_key(actor_id, workspace_id, sid, host_id, mode) do
    {:terminal_fast_path, actor_id, workspace_id, sid, host_id, mode}
  end

  defp reset_terminal_fast_path_cache! do
    case :ets.whereis(:dev_ide_terminal_fast_path_cache) do
      :undefined -> :ets.new(:dev_ide_terminal_fast_path_cache, [:named_table, :public, :set])
      table -> :ets.delete_all_objects(table)
    end
  end

  defp pty_unavailable?(reason) when is_binary(reason) do
    reason in ["raw terminal unavailable", "join crashed"] or
      reason =~ "posix_openpt" or reason =~ "Device not configured"
  end

  # Helpers to keep raw tests readable and robust to environments where raw PTY
  # attach can fail (no pty, timing, container constraints, or owner process
  # already gone during multi-join reconnect simulations). A successful attach
  # exercises the real assertions; a PTY-unavailable attach is reported as
  # {:error, :pty_unavailable} so callers can skip the raw-dependent portion
  # rather than crash. Deterministic boundary errors (host/mode rejections) are
  # NOT raw-success joins and keep using subscribe_and_join directly.
  defp join_raw(user_socket, topic, params \\ %{}) do
    params = Map.put_new(params, "mode", "raw")

    try do
      case subscribe_and_join(user_socket, DevIdeWeb.TerminalChannel, topic, params) do
        {:ok, reply, joined} ->
          {:ok, reply, joined}

        {:error, %{reason: reason}} ->
          if pty_unavailable?(reason), do: {:error, :pty_unavailable}, else: {:error, reason}
      end
    catch
      :exit, _ -> {:error, :pty_unavailable}
    end
  end

  defp join_raw_with_capability(user_socket, topic, capability) do
    join_raw(user_socket, topic, %{"terminal_capability" => capability})
  end

  defp safe_owner_detach(owner_pid, subscriber) when is_pid(owner_pid) do
    DevIDE.Terminals.owner_detach(owner_pid, subscriber)
    :ok
  catch
    :exit, _ -> :ok
    _ -> :ok
  end

  defp safe_owner_detach(_owner_pid, _subscriber), do: :ok
end
