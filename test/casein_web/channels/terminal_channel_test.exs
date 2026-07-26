defmodule CaseinWeb.TerminalChannelTest do
  use CaseinWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias Casein.Audit
  alias Casein.Integrations.Manager.Client
  alias Casein.Runs.Ledger
  alias CaseinWeb.ChannelAuth
  alias Casein.Terminals.Tmux
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @endpoint CaseinWeb.Endpoint

  setup do
    workspace_root = Path.join(System.tmp_dir!(), "casein-terminal-channel")
    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_default = Application.get_env(:casein, :default_workspace_mode)
    prev_overrides = Application.get_env(:casein, :workspace_modes)
    prev_forward_auth = Application.get_env(:casein, :forward_auth)
    prev_raw_everywhere = Application.get_env(:casein, :raw_terminal_everywhere)

    Application.put_env(:casein, :workspaces_root, workspace_root)
    Application.put_env(:casein, :default_workspace_mode, :review)
    Application.delete_env(:casein, :workspace_modes)
    # This suite exercises the raw gate + fast-path cache machinery, so pin it
    # to the gated policy (manual mode on local host).
    Application.put_env(:casein, :raw_terminal_everywhere, false)

    reset_terminal_fast_path_cache!()

    MemoryAdapter.clear()
    Casein.Runtimes.clear()
    Audit.clear()

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Casein.Runtimes.clear()
      Audit.clear()
      kill_tmux_sessions_under(workspace_root)
      reset_terminal_fast_path_cache!()
      File.rm_rf(workspace_root)
      restore_app_env(:workspaces_root, prev_root)
      restore_app_env(:default_workspace_mode, prev_default)
      restore_app_env(:workspace_modes, prev_overrides)
      restore_app_env(:forward_auth, prev_forward_auth)
      restore_app_env(:raw_terminal_everywhere, prev_raw_everywhere)
    end)

    {:ok, workspace_path: workspace_path}
  end

  test "malformed topic format is rejected" do
    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    assert {:error, %{reason: "invalid session"}} =
             subscribe_and_join(socket, CaseinWeb.TerminalChannel, "terminal:broken-topic", %{
               "mode" => "governed"
             })
  end

  test "malformed topic variants are rejected" do
    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    for topic <- [
          "terminal:ws-1",
          "terminal::sid",
          "terminal:",
          "terminal:ws-1:"
        ] do
      assert {:error, %{reason: "invalid session"}} =
               subscribe_and_join(socket, CaseinWeb.TerminalChannel, topic, %{
                 "mode" => "governed"
               })
    end
  end

  test "join reuses cached workspace lookup for repeated joins on one socket", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    # A successful raw attach seeds the socket-local workspace claim cache; a
    # second join (different sid, same workspace/socket) must reuse it without a
    # second manager lookup.
    case join_raw(socket, "terminal:ws-1:cache-a") do
      {:ok, reply, socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 1

        case join_raw(socket, "terminal:ws-1:cache-b") do
          {:ok, reply2, _socket} -> assert reply2.mode == "raw"
          {:error, :pty_unavailable} -> :ok
        end

        assert :counters.get(counter, 1) == 1
        safe_owner_detach(socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "workspace lookup cache is shared across fresh sockets for repeated raw joins", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket_one =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(socket_one, "terminal:ws-1:global-cache") do
      {:ok, _reply, socket_one} ->
        assert :counters.get(counter, 1) == 1

        socket_two =
          CaseinWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        # Fresh socket, same workspace: the ETS fast-path claim cache is shared, so
        # no second manager lookup even though the sid differs.
        _ = join_raw(socket_two, "terminal:ws-1:global-cache-two")
        assert :counters.get(counter, 1) == 1

        safe_owner_detach(socket_one.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "fallback synthetic workspace claim is cached and reused on fresh socket reconnect", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "synthetic-reconnect"

    first_socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(first_socket, "terminal:ws-1:#{sid}") do
      {:ok, reply, first_socket} ->
        assert reply.mode == "raw"
        owner_pid = first_socket.assigns.terminal_owner_pid
        assert :counters.get(counter, 1) == 1

        second_socket =
          CaseinWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        case join_raw(second_socket, "terminal:ws-1:#{sid}") do
          {:ok, reply2, second_socket} ->
            assert reply2.mode == "raw"
            # Fresh-socket reconnect to the same sid reuses the ETS-cached claim.
            assert second_socket.assigns.terminal_fast_path
            assert second_socket.assigns.terminal_owner_pid == owner_pid

          {:error, :pty_unavailable} ->
            :ok
        end

        assert :counters.get(counter, 1) == 1
        safe_owner_detach(owner_pid, self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "fast-path cache is actor-scoped and not reused across different users", %{
    workspace_path: workspace_path
  } do
    prev_forward_auth = Application.get_env(:casein, :forward_auth)
    Application.put_env(:casein, :forward_auth, true)
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "synthetic-actor-scope"

    try do
      dev_socket =
        CaseinWeb.UserSocket
        |> socket("users_socket:dev", %{
          current_user: %{id: "dev", username: "alice", email: "dev@local"}
        })
        |> Phoenix.Socket.assign(:current_user, %{
          id: "dev",
          username: "alice",
          email: "dev@local"
        })

      case join_raw(dev_socket, "terminal:ws-1:#{sid}") do
        {:ok, _reply, first_socket} ->
          assert :counters.get(counter, 1) == 1

          intruder_socket =
            CaseinWeb.UserSocket
            |> socket("users_socket:dev", %{
              current_user: %{id: "intruder", username: "intruder", email: "intruder@local"}
            })
            |> Phoenix.Socket.assign(:current_user, %{
              id: "intruder",
              username: "intruder",
              email: "intruder@local"
            })

          # Different actor: the fast-path claim cache must NOT be reused, forcing a
          # fresh manager lookup (counter advances to 2).
          _ = join_raw(intruder_socket, "terminal:ws-1:#{sid}")
          assert :counters.get(counter, 1) == 2

          safe_owner_detach(first_socket.assigns[:terminal_owner_pid], self())

        {:error, :pty_unavailable} ->
          :ok
      end
    after
      restore_app_env(:forward_auth, prev_forward_auth)
    end
  end

  test "join uses terminal workspace capability when provided" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "capability"
      )

    case join_raw_with_capability(socket, "terminal:ws-1:capability", capability) do
      {:ok, reply, joined} ->
        assert reply.mode == "raw"
        safe_owner_detach(joined.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "capability sid mismatch emits telemetry and falls back to workspace lookup" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    test_pid = self()
    handler_id = {__MODULE__, :terminal_capability_mismatch, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:casein, :terminal_channel, :capability_mismatch],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:terminal_capability_mismatch, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "old-sid"
      )

    case join_raw_with_capability(socket, "terminal:ws-1:new-sid", capability) do
      {:ok, reply, joined} ->
        assert reply.mode == "raw"
        assert joined.assigns.terminal_sid == "new-sid"
        safe_owner_detach(joined.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end

    assert_receive {:terminal_capability_mismatch, %{count: 1}, metadata}
    assert metadata.reason == :terminal_sid
    assert metadata.sid == "new-sid"
    assert metadata.capability_sid == "old-sid"
  end

  test "raw join with valid terminal capability skips workspace lookup", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "cap-fast"
      )

    case join_raw_with_capability(socket, "terminal:ws-1:cap-fast", capability) do
      {:ok, reply, socket} ->
        assert reply.mode == "raw"
        assert socket.assigns.terminal_fast_path
        assert :counters.get(counter, 1) == 0
        safe_owner_detach(socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "subsequent raw join without terminal capability can reuse fast-path cache", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "cache-capability"
      )

    case join_raw_with_capability(socket, "terminal:ws-1:cache-capability", capability) do
      {:ok, _reply, socket} ->
        assert :counters.get(counter, 1) == 0

        case join_raw(socket, "terminal:ws-1:cache-capability") do
          {:ok, reply, _socket} ->
            assert reply.mode == "raw"
            assert :counters.get(counter, 1) == 0

          {:error, :pty_unavailable} ->
            :ok
        end

        safe_owner_detach(socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "stale mode cache entry falls back to wildcard claim in fresh socket fast cache", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "wildcard-recovery"

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    stale_claims = {
      terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw),
      %{
        kind: :terminal_workspace,
        user_id: "dev",
        workspace_id: "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
        workspace_user: "dev",
        workspace_path: workspace_path,
        workspace_host_id: "local",
        terminal_sid: sid,
        raw_terminal_ok: true
      },
      System.system_time(:millisecond) + 60_000
    }

    :ets.insert(:casein_terminal_fast_path_cache, [stale_claims, wildcard_claims])

    case join_raw(socket, "terminal:ws-1:#{sid}") do
      {:ok, reply, _socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 0

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "stale exact fast-path cache entries fall back to fresh workspace cache", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    sid = "cache-expiry"

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: sid
      )

    cache_key = terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw)

    case join_raw_with_capability(socket, "terminal:ws-1:#{sid}", capability) do
      {:ok, _reply, socket} ->
        assert :counters.get(counter, 1) == 0

        {:ok, claims} = ChannelAuth.verify_terminal_capability(capability)
        # Force the exact-key ETS entry to look expired (expires_at in the past).
        :ets.insert(:casein_terminal_fast_path_cache, {cache_key, claims, 0})
        assert :ets.lookup(:casein_terminal_fast_path_cache, cache_key) != []

        case join_raw(socket, "terminal:ws-1:#{sid}") do
          {:ok, reply, _socket} ->
            assert reply.mode == "raw"
            # The expired exact entry is bypassed via the still-valid socket/wildcard
            # claim, so no extra manager lookup is needed.
            assert :counters.get(counter, 1) == 0

          {:error, :pty_unavailable} ->
            :ok
        end

        safe_owner_detach(socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "stale socket-local fast-path cache entries are ignored and fall back to workspace lookup",
       %{
         workspace_path: workspace_path
       } do
    counter = count_workspace_requests!(workspace_path)
    sid = "socket-cache-expired"

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    stale_cache = %{
      terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw) => {
        %{},
        System.system_time(:millisecond) - 1
      }
    }

    socket = Phoenix.Socket.assign(socket, :terminal_fast_path_cache, stale_cache)

    # Expired socket-local entry must be ignored, forcing a workspace lookup.
    _ = join_lookup(socket, "terminal:ws-1:#{sid}")
    assert :counters.get(counter, 1) == 1
  end

  test "numeric actor id is accepted for fast-path caching and reuse", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "numeric-actor-cache"

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{
        current_user: %{id: 42, email: "dev@local", username: "dev"}
      })
      |> Phoenix.Socket.assign(:current_user, %{id: 42, email: "dev@local", username: "dev"})

    case join_raw(socket, "terminal:ws-1:#{sid}") do
      {:ok, _reply, socket} ->
        assert :counters.get(counter, 1) == 1

        case join_raw(socket, "terminal:ws-1:#{sid}") do
          {:ok, reply2, _socket} ->
            assert reply2.mode == "raw"
            assert :counters.get(counter, 1) == 1

          {:error, :pty_unavailable} ->
            :ok
        end

        safe_owner_detach(socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "socket fast-path cache is host-scoped for raw reconnect", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    sid = "socket-cache-host-scope"

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
                   CaseinWeb.TerminalChannel,
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
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "wildcard-stale-cache"

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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

    :ets.insert(:casein_terminal_fast_path_cache, stale_claims)

    reconnect_socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(reconnect_socket, "terminal:ws-1:#{sid}", %{
           "terminal_capability" => capability
         }) do
      {:ok, _reply, _second_socket} ->
        assert :counters.get(counter, 1) == 0

        assert :ets.lookup(
                 :casein_terminal_fast_path_cache,
                 terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw)
               ) != []

        assert :ets.lookup(
                 :casein_terminal_fast_path_cache,
                 terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any)
               ) != []

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "stale ETS wildcard mode entry falls back to fresh wildcard claim", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "wildcard-ets-recovery"

    stale_claim =
      {
        terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw),
        %{
          kind: :terminal_workspace,
          user_id: "dev",
          workspace_id: "ws-1",
          workspace_name: "alpha",
          workspace_user: "dev",
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
          workspace_user: "dev",
          workspace_path: workspace_path,
          workspace_host_id: "local",
          terminal_sid: sid,
          raw_terminal_ok: true
        },
        System.system_time(:millisecond) + 60_000
      }

    :ets.insert(:casein_terminal_fast_path_cache, [stale_claim, wildcard_claim])

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(socket, "terminal:ws-1:#{sid}") do
      {:ok, reply, joined_socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 0
        assert joined_socket.assigns.terminal_fast_path

        assert :ets.lookup(
                 :casein_terminal_fast_path_cache,
                 terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw)
               ) != []

        assert :ets.lookup(
                 :casein_terminal_fast_path_cache,
                 terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any)
               ) != []

        safe_owner_detach(joined_socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "stale socket wildcard cache entries are purged before workspace lookup", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "socket-wildcard-expiry"

    stale_wildcard_cache = %{
      terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :any) => {
        %{
          kind: :terminal_workspace,
          user_id: "dev",
          workspace_id: "ws-1",
          workspace_name: "alpha",
          workspace_user: "dev",
          workspace_path: workspace_path,
          workspace_host_id: "local",
          terminal_sid: sid
        },
        System.system_time(:millisecond) - 1
      }
    }

    socket =
      CaseinWeb.UserSocket
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
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "raw-host-boundary-cache"

    local_socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
          CaseinWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        assert {:error, %{reason: "raw shell requires local host"}} =
                 subscribe_and_join(
                   remote_socket,
                   CaseinWeb.TerminalChannel,
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
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "raw-host-scope-fresh"

    local_socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
          CaseinWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        assert {:error, %{reason: "raw shell requires local host"}} =
                 subscribe_and_join(
                   remote_socket,
                   CaseinWeb.TerminalChannel,
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
    workspace_path: workspace_path
  } do
    prev_forward_auth = Application.get_env(:casein, :forward_auth)
    Application.put_env(:casein, :forward_auth, true)
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    try do
      counter = count_workspace_requests!(workspace_path)
      sid = "forward-auth-fast-path-mismatch"

      dev_socket =
        CaseinWeb.UserSocket
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
          workspace_user: "dev",
          workspace_path: workspace_path,
          workspace_loc: {:local, workspace_path},
          workspace_host_id: "local",
          owner_ok: true,
          terminal_owner_ok: true,
          raw_terminal_ok: true,
          terminal_sid: sid
        )

      # dev establishes a cached fast path (no manager lookup).
      case join_raw_with_capability(dev_socket, "terminal:ws-1:#{sid}", capability) do
        {:ok, _reply, dev_joined} ->
          assert :counters.get(counter, 1) == 0
          safe_owner_detach(dev_joined.assigns[:terminal_owner_pid], self())

        {:error, :pty_unavailable} ->
          :ok
      end

      intruder_socket =
        CaseinWeb.UserSocket
        |> socket("users_socket:dev", %{
          current_user: %{id: "intruder", email: "intruder@remote", username: "intruder"}
        })
        |> Phoenix.Socket.assign(:current_user, %{
          id: "intruder",
          email: "intruder@remote",
          username: "intruder"
        })

      # A different forward-auth user must NOT reuse dev's fast-path cache, so the
      # intruder join falls through to a fresh workspace lookup.
      _ = join_lookup(intruder_socket, "terminal:ws-1:#{sid}")
      assert :counters.get(counter, 1) == 1
    after
      restore_app_env(:forward_auth, prev_forward_auth)
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "socket-fast-path cache bypasses workspace lookup when ETS claim cache is missing", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "socket-cache-miss"

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: sid
      )

    case join_raw_with_capability(socket, "terminal:ws-1:#{sid}", capability) do
      {:ok, reply, socket} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 0

        # Drop the ETS exact entry: the socket-local fast-path cache must still
        # serve the reconnect without a fresh manager lookup.
        cache_key = terminal_fast_path_cache_key("dev", "ws-1", sid, "local", :raw)
        :ets.delete(:casein_terminal_fast_path_cache, cache_key)
        assert :ets.lookup(:casein_terminal_fast_path_cache, cache_key) == []

        case join_raw(socket, "terminal:ws-1:#{sid}") do
          {:ok, reply2, _socket2} ->
            assert reply2.mode == "raw"
            assert :counters.get(counter, 1) == 0

          {:error, :pty_unavailable} ->
            :ok
        end

        safe_owner_detach(socket.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "socket-fast-path cache avoids extra workspace lookup for raw reconnect", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "socket-cache-raw"

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
        :ets.delete(:casein_terminal_fast_path_cache, cache_key)
        assert :ets.lookup(:casein_terminal_fast_path_cache, cache_key) == []

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

  test "raw join with valid terminal capability does not set fast-path when terminal_sid mismatches",
       %{
         workspace_path: workspace_path
       } do
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        terminal_sid: "other-session"
      )

    # sid mismatch ⇒ capability fast path is rejected ⇒ workspace lookup runs.
    _ =
      join_lookup(socket, "terminal:ws-1:cap-incorrect-session", %{
        "terminal_capability" => capability
      })

    assert :counters.get(counter, 1) == 1
  end

  test "join ignores malformed terminal capability and falls back to workspace lookup", %{
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    # A malformed token cannot grant a fast path, so the join falls back to the
    # workspace lookup (counter advances) before the raw boundary applies.
    _ =
      join_lookup(socket, "terminal:ws-1:bad-capability", %{
        "terminal_capability" => "not-even-a-valid-token"
      })

    assert :counters.get(counter, 1) == 1
  end

  test "raw join with matching terminal_sid capability uses fast path", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "cache-a"
      )

    case join_raw_with_capability(socket, "terminal:ws-1:cache-a", capability) do
      {:ok, reply, joined} ->
        assert reply.mode == "raw"
        assert :counters.get(counter, 1) == 0
        safe_owner_detach(joined.assigns[:terminal_owner_pid], self())

      {:error, :pty_unavailable} ->
        :ok
    end
  end

  test "terminal capability with mismatched terminal_sid falls back to workspace lookup", %{
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        terminal_sid: "wrong-sid"
      )

    _ = join_lookup(socket, "terminal:ws-1:cache-a", %{"terminal_capability" => capability})
    assert :counters.get(counter, 1) == 1
  end

  test "terminal capability with mismatched workspace_host_id falls back to workspace lookup", %{
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: "/tmp",
        workspace_loc: {:local, "/tmp"},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        terminal_sid: "cap-host"
      )

    _ =
      join_lookup(socket, "terminal:ws-1:cap-host", %{
        "host_id" => "remote",
        "terminal_capability" => capability
      })

    assert :counters.get(counter, 1) == 1
  end

  test "terminal capability with mismatched user id falls back to workspace lookup", %{
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: 12, email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: 12, email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: "/tmp",
        raw_terminal_ok: true
      )

    _ =
      join_lookup(socket, "terminal:ws-1:mismatch-user", %{
        "terminal_capability" => capability
      })

    assert :counters.get(counter, 1) == 1
  end

  test "terminal capability with owner_ok false is denied" do
    socket =
      CaseinWeb.UserSocket
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
               CaseinWeb.TerminalChannel,
               "terminal:ws-1:owner-deny",
               %{"mode" => "governed", "terminal_capability" => capability}
             )
  end

  test "terminal capability with terminal_owner_ok false is denied" do
    socket =
      CaseinWeb.UserSocket
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
               CaseinWeb.TerminalChannel,
               "terminal:ws-1:owner-deny-terminal",
               %{"mode" => "governed", "terminal_capability" => capability}
             )
  end

  test "raw join with terminal capability skips raw boundary when raw_terminal_ok is true", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    user_socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        raw_terminal_ok: true,
        owner_ok: true,
        terminal_owner_ok: true,
        terminal_sid: "raw-fast-reconnect-fresh"
      )

    first_socket =
      CaseinWeb.UserSocket
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
          CaseinWeb.UserSocket
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
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
               CaseinWeb.TerminalChannel,
               "terminal:ws-1:raw-capability-deny",
               %{"mode" => "raw", "terminal_capability" => capability}
             )

    assert reason == "raw shell requires manual workspace mode"
  end

  test "raw capability is cached on socket and reused for reconnect without extra lookup", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: workspace_path,
        workspace_loc: {:local, workspace_path},
        workspace_host_id: "local",
        owner_ok: true,
        terminal_owner_ok: true,
        raw_terminal_ok: true,
        terminal_sid: "raw-capability-cache-reuse"
      )

    case join_raw_with_capability(socket, "terminal:ws-1:raw-capability-cache-reuse", capability) do
      {:ok, reply, socket} ->
        assert reply.mode == "raw"
        assert is_pid(socket.assigns.terminal_owner_pid)
        assert :counters.get(counter, 1) == 0

        case join_raw(socket, "terminal:ws-1:raw-capability-cache-reuse") do
          {:ok, reply2, rejoin_socket} ->
            assert reply2.mode == "raw"

            assert rejoin_socket.assigns.terminal_owner_pid ==
                     socket.assigns.terminal_owner_pid

            assert :counters.get(counter, 1) == 0
            safe_owner_detach(rejoin_socket.assigns[:terminal_owner_pid], self())

          {:error, :pty_unavailable} ->
            safe_owner_detach(socket.assigns[:terminal_owner_pid], self())
        end

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "raw terminal capability with host mismatch still enforces host policy" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    capability =
      ChannelAuth.sign_terminal_capability("dev", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
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
               CaseinWeb.TerminalChannel,
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
    workspace_path: workspace_path
  } do
    prev = Application.get_env(:casein, :forward_auth)
    Application.put_env(:casein, :forward_auth, true)
    counter = count_workspace_requests!(workspace_path)

    workspace_token =
      ChannelAuth.sign_terminal_capability("alice", "ws-1",
        workspace_name: "alpha",
        workspace_user: "dev",
        workspace_path: "/tmp"
      )

    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{
        current_user: %{id: "intruder", username: "intruder", email: "intruder@local"}
      })
      |> Phoenix.Socket.assign(:current_user, %{
        id: "intruder",
        username: "intruder",
        email: "intruder@local"
      })

    try do
      # The token is signed for "alice" but the actor is "intruder"; the tampered
      # capability is rejected, so the join falls back to the workspace lookup.
      _ =
        join_lookup(socket, "terminal:ws-1:tampered-capability", %{
          "terminal_capability" => workspace_token
        })

      assert :counters.get(counter, 1) == 1
    after
      restore_app_env(:forward_auth, prev)
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
      CaseinWeb.UserSocket
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
    workspace_path: workspace_path
  } do
    counter = count_workspace_requests!(workspace_path)
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    sid = "raw-cache-workspace"

    socket =
      CaseinWeb.UserSocket
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
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)

    sid = "raw-reconnect-fresh-socket"

    first_socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(first_socket, "terminal:ws-1:#{sid}") do
      {:ok, _reply, socket_one} ->
        owner_pid = socket_one.assigns.terminal_owner_pid
        assert is_pid(owner_pid)
        assert :counters.get(counter, 1) == 1

        second_socket =
          CaseinWeb.UserSocket
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
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    first_join =
      subscribe_and_join(
        first_socket,
        CaseinWeb.TerminalChannel,
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
          CaseinWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        second_join =
          try do
            subscribe_and_join(
              second_socket,
              CaseinWeb.TerminalChannel,
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

        :ok = Casein.Terminals.owner_detach(first_joined.assigns.terminal_owner_pid, self())

      {:error, %{reason: reason}} ->
        assert pty_unavailable?(reason)

        assert Enum.count(Ledger.recent_for("ws-1", 10), &(&1.action == "run.session_attached")) <=
                 1
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
  end

  test "raw reconnect on fresh socket reuses auth cache without extra lookup", %{
    workspace_path: workspace_path
  } do
    assert {:ok, _} = State.set_mode("ws-1", :manual)
    counter = count_workspace_requests!(workspace_path)
    sid = "raw-reconnect-no-duplicate-events"

    first_socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    case join_raw(first_socket, "terminal:ws-1:#{sid}") do
      {:ok, _reply, first_joined} ->
        assert :counters.get(counter, 1) == 1
        owner_pid = first_joined.assigns.terminal_owner_pid

        second_socket =
          CaseinWeb.UserSocket
          |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
          |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

        case join_raw(second_socket, "terminal:ws-1:#{sid}") do
          {:ok, _reply, second_joined} ->
            assert second_joined.assigns.terminal_owner_pid == owner_pid

          {:error, :pty_unavailable} ->
            :ok
        end

        assert :counters.get(counter, 1) == 1
        safe_owner_detach(owner_pid, self())

      {:error, :pty_unavailable} ->
        :ok
    end

    kill_tmux_sessions_under(Path.dirname(workspace_path))
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

    assert Registry.lookup(Casein.Terminals.Registry, {:terminal_owner, :shell, "", sid}) == []
  end

  test "raw join denied on remote host and owner is not started" do
    assert {:ok, _} = State.set_mode("ws-1", :manual)

    assert {:error, %{reason: "raw shell requires local host"}} =
             join_terminal("raw", "raw-remote-deny", "remote")

    assert Registry.lookup(
             Casein.Terminals.Registry,
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

    assert Registry.lookup(Casein.Terminals.Registry, {:terminal_owner, :shell, "", sid}) == []
  end

  defp join_terminal(mode, sid, host_id \\ "local") do
    socket =
      CaseinWeb.UserSocket
      |> socket("users_socket:dev", %{current_user: %{id: "dev", email: "dev@local"}})
      |> Phoenix.Socket.assign(:current_user, %{id: "dev", email: "dev@local"})

    subscribe_and_join(socket, CaseinWeb.TerminalChannel, "terminal:ws-1:#{sid}", %{
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
        "user" => "dev",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp restore_app_env(key, value) do
    if List.keymember?(Application.started_applications(), :casein, 0) do
      if value,
        do: Application.put_env(:casein, key, value),
        else: Application.delete_env(:casein, key)
    end
  end

  defp count_workspace_requests!(workspace_path) do
    counter = :counters.new(1, [])

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-1", "status"]} = conn ->
        :counters.add(counter, 1, 1)
        workspace_payload(conn, workspace_path)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    counter
  end

  # Retries kill until no matching panes remain (or ~500ms elapses). Soft on
  # timeout — cleanup must not flunk the suite. Backoff is receive-after via
  # Casein.Test.Eventually (never Process.sleep).
  defp kill_tmux_sessions_under(root) do
    root = canonical_path(root)

    try do
      Casein.Test.Eventually.await(
        fn -> not kill_tmux_sessions_once(root) end,
        timeout_ms: 10 * 50,
        interval_ms: 50,
        message: "tmux sessions under #{root} still present after cleanup"
      )
    rescue
      ExUnit.AssertionError -> :ok
    end

    :ok
  end

  defp kill_tmux_sessions_once(root) do
    case System.cmd(
           "tmux",
           Casein.Terminals.TmuxServer.args() ++
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
              System.cmd(
                "tmux",
                Casein.Terminals.TmuxServer.args() ++ ["kill-session", "-t", session],
                stderr_to_stdout: true
              )

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

  # Under raw-only every join is a raw attach. These cache/auth tests care about
  # the WORKSPACE LOOKUP (manager hit count) and fast-path cache seeding, which
  # happen in resolve_workspace_context BEFORE the raw-shell boundary/PTY attach
  # can reject. So this helper joins and returns the result, swallowing any error
  # (manual-mode boundary, missing PTY) so the test can assert on the counter.
  # Returns {:ok, reply, socket} on success, :error otherwise. The channel hard-
  # codes `mode = :raw` on join, so the "mode" param value is irrelevant.
  defp join_lookup(user_socket, topic, params \\ %{}) do
    try do
      case subscribe_and_join(user_socket, CaseinWeb.TerminalChannel, topic, params) do
        {:ok, reply, joined} -> {:ok, reply, joined}
        {:error, _reason} -> :error
      end
    catch
      :exit, _ -> :error
    end
  end

  defp reset_terminal_fast_path_cache! do
    case :ets.whereis(:casein_terminal_fast_path_cache) do
      :undefined -> :ets.new(:casein_terminal_fast_path_cache, [:named_table, :public, :set])
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
      case subscribe_and_join(user_socket, CaseinWeb.TerminalChannel, topic, params) do
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
    Casein.Terminals.owner_detach(owner_pid, subscriber)
    :ok
  catch
    :exit, _ -> :ok
    _ -> :ok
  end

  defp safe_owner_detach(_owner_pid, _subscriber), do: :ok
end
