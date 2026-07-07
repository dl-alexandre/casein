defmodule DevIDE.Terminals.SessionOwnerTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals
  alias DevIDE.Terminals.Telemetry
  alias DevIDE.Terminals.Session.Info
  alias DevIDE.Terminals.{CommandLog, SessionEvents}

  test "shell owners remain alive after explicit detach (no auto-stop)" do
    info = Terminals.new_shell("ws-shell-stop", "shell-keep-alive")

    owner_pid = start_shell_owner("ws-shell-stop", info)
    register_subscriber(owner_pid, self(), :raw)

    assert Process.alive?(owner_pid)

    monitor = Process.monitor(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, self())
    refute_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 500

    assert match?(
             [{^owner_pid, _}],
             Registry.lookup(
               DevIDE.Terminals.Registry,
               {:terminal_owner, :shell, "ws-shell-stop", "shell-keep-alive"}
             )
           )

    GenServer.stop(owner_pid, :normal)
  end

  test "ephemeral owners stop when no subscribers remain" do
    info = Info.new_agent("agent-stop-1", workspace_id: "ws-agent-stop-1")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-stop-1", info, mode: :raw, session_id: "agent-stop-1")

    monitor = Process.monitor(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, self())

    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "ephemeral owners only stop after all subscribers detach" do
    info = Info.new_agent("agent-shared-stop", workspace_id: "ws-agent-shared-stop")

    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-shared-stop", info,
        mode: :raw,
        session_id: "agent-shared-stop"
      )

    monitor = Process.monitor(owner_pid)

    secondary =
      spawn(fn ->
        {:ok, _sec_owner_pid, _} =
          Terminals.owner_attach("ws-agent-shared-stop", info,
            mode: :raw,
            session_id: "agent-shared-stop"
          )

        send(parent, :secondary_attached)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :secondary_attached, 1_000

    assert :ok = Terminals.owner_detach(owner_pid, self())
    refute_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 400

    send(secondary, :release)
    assert :ok = Terminals.owner_detach(owner_pid, secondary)
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "detaching a non-subscriber on an ephemeral owner is a no-op" do
    info = Info.new_agent("agent-idempotent", workspace_id: "ws-agent-idempotent")

    bogus =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-idempotent", info,
        mode: :raw,
        session_id: "agent-idempotent"
      )

    monitor = Process.monitor(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, bogus)
    assert Process.alive?(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
    Process.exit(bogus, :kill)
  end

  test "subscriber exits are cleaned up via monitor and do not stop owner while others remain" do
    info = Info.new_agent("agent-exit-cleanup", workspace_id: "ws-agent-exit-cleanup")

    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-exit-cleanup", info,
        mode: :raw,
        session_id: "agent-exit-cleanup"
      )

    monitor = Process.monitor(owner_pid)

    subscriber =
      spawn(fn ->
        {:ok, ^owner_pid, _} =
          Terminals.owner_attach("ws-agent-exit-cleanup", info,
            mode: :raw,
            session_id: "agent-exit-cleanup"
          )

        send(parent, :subscriber_attached)

        receive do
          :terminate -> :ok
        end
      end)

    assert_receive :subscriber_attached, 1_000

    Process.exit(subscriber, :kill)
    refute_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 250
    assert Terminals.owner_subscriber_count(owner_pid) == 1

    :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "agent owners stop when no subscribers remain" do
    info = Info.new_agent("agent-stop", workspace_id: "ws-agent-stop")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-stop", info, mode: :raw, session_id: "agent-stop")

    monitor = Process.monitor(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "raw re-attachments receive bounded terminal replay from owner" do
    info = Terminals.new_shell("ws-shell-replay", "sid-replay")

    parent = self()
    owner_pid = start_shell_owner("ws-shell-replay", info)
    seed_stub_attachment(owner_pid)

    # A first raw subscriber must be present so the owner captures live output
    # into its replay_buffer.
    first = spawn(fn -> relay(parent, :first) end)
    register_subscriber(owner_pid, first, :raw)

    send(owner_pid, {:term_data, :ignore, "before-replay-1", :replay})
    send(owner_pid, {:term_data, :ignore, "before-replay-2"})

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-shell-replay", info, mode: :raw, session_id: "sid-replay")

        relay(parent, :second)
      end)

    assert_receive {:second, %{data: data, replay: true}}, 1_500
    assert data =~ "before-replay-1"
    assert data =~ "before-replay-2"

    Process.exit(first, :kill)
    Process.exit(second, :kill)

    GenServer.stop(owner_pid, :normal)
  end

  test "raw replay payload strips cursor report escape sequence" do
    info = Terminals.new_shell("ws-shell-control", "sid-control")

    parent = self()
    owner_pid = start_shell_owner("ws-shell-control", info)
    seed_stub_attachment(owner_pid)

    first = spawn(fn -> relay(parent, :control_first) end)
    register_subscriber(owner_pid, first, :raw)

    send(owner_pid, {:term_data, :ignore, "\e[12;34Rhello", :replay})

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-shell-control", info, mode: :raw, session_id: "sid-control")

        relay(parent, :control_second)
      end)

    assert_receive {:control_second, payload}, 1_500
    assert payload.data == "hello"
    assert payload.replay == true
    refute String.contains?(payload.data, "\e[")

    Process.exit(first, :kill)
    Process.exit(second, :kill)

    GenServer.stop(owner_pid, :normal)
  end

  test "raw replay payload strips terminal capability handshakes" do
    info = Terminals.new_shell("ws-shell-xtversion", "sid-xtversion")

    parent = self()
    owner_pid = start_shell_owner("ws-shell-xtversion", info)
    seed_stub_attachment(owner_pid)

    first = spawn(fn -> relay(parent, :xtversion_first) end)
    register_subscriber(owner_pid, first, :raw)

    send(
      owner_pid,
      {:term_data, :ignore, "before\e[>q\eP>|libghostty\e\\\e[c\e[?62;22c\e[>1;0;0cafter",
       :replay}
    )

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-shell-xtversion", info,
            mode: :raw,
            session_id: "sid-xtversion"
          )

        relay(parent, :xtversion_second)
      end)

    assert_receive {:xtversion_second, payload}, 1_500
    assert payload.data == "beforeafter"
    assert payload.replay == true
    refute String.contains?(payload.data, "\e[>q")
    refute String.contains?(payload.data, "libghostty")
    refute String.contains?(payload.data, "62;22c")
    refute String.contains?(payload.data, "1;0;0c")

    Process.exit(first, :kill)
    Process.exit(second, :kill)

    GenServer.stop(owner_pid, :normal)
  end

  test "raw re-attach replays the buffer accumulated while attached (reconnect UX)" do
    info = Terminals.new_shell("ws-shell-no-raw", "sid-no-raw")

    owner_pid = start_shell_owner("ws-shell-no-raw", info)
    seed_stub_attachment(owner_pid)
    register_subscriber(owner_pid, self(), :raw)

    send(owner_pid, {:term_data, :ignore, "pre-reconnect", :replay})
    assert_receive {:terminal_payload, :data, %{data: "pre-reconnect"}}, 1_000

    # A raw re-attach (same subscriber) replays the buffered output for
    # reconnect UX — the buffer was captured because a raw subscriber was active.
    assert {:ok, ^owner_pid, _} =
             Terminals.owner_attach(
               "ws-shell-no-raw",
               info,
               mode: :raw,
               session_id: "sid-no-raw"
             )

    assert_receive {:terminal_payload, :data, %{replay: true, data: replay}}, 1_000
    assert replay =~ "pre-reconnect"

    send(owner_pid, {:term_data, :ignore, "after-reconnect", :replay})
    assert_receive {:terminal_payload, :data, %{data: "after-reconnect"}}, 1_000
    GenServer.stop(owner_pid, :normal)
  end

  test "raw owner accepts Ghostty PTY write calls without crashing" do
    info = Terminals.new_shell("ws-shell-ghostty-write", "sid-ghostty-write")

    owner_pid = start_shell_owner("ws-shell-ghostty-write", info)
    seed_stub_attachment(owner_pid)
    register_subscriber(owner_pid, self(), :raw)

    monitor = Process.monitor(owner_pid)

    assert :ok = GenServer.call(owner_pid, {:write, "o"})
    assert :ok = GenServer.call(owner_pid, {:write, "\e[I"})
    refute_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason}, 250

    GenServer.stop(owner_pid, :normal)
  end

  test "raw attach enables replay buffering for output replay" do
    info = Terminals.new_shell("ws-shell-raw-buffer-turn-on", "sid-raw-buffer-turn-on")

    parent = self()

    owner_pid = start_shell_owner("ws-shell-raw-buffer-turn-on", info)
    seed_stub_attachment(owner_pid)
    register_subscriber(owner_pid, self(), :raw)

    send(owner_pid, {:term_data, :ignore, "raw-snapshot", :replay})

    second =
      spawn(fn ->
        {:ok, ^owner_pid, _} =
          Terminals.owner_attach(
            "ws-shell-raw-buffer-turn-on",
            info,
            mode: :raw,
            session_id: "sid-raw-buffer-turn-on"
          )

        relay(parent, :raw_replay_second)
      end)

    assert_receive {:raw_replay_second, payload}, 1_000
    assert payload.replay == true
    assert payload.data == "raw-snapshot"

    send(owner_pid, {:term_data, :ignore, "raw-live"})
    assert_receive {:terminal_payload, :data, %{data: "raw-live"}}, 1_000
    assert byte_size(:sys.get_state(owner_pid).replay_buffer) > 0

    Process.exit(second, :kill)
    GenServer.stop(owner_pid, :normal)
  end

  test "non-binary term_data is ignored without stopping the owner" do
    info = Info.new_agent("agent-bad-data", workspace_id: "ws-agent-bad-data")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-bad-data", info, mode: :raw, session_id: "bad-data")

    monitor = Process.monitor(owner_pid)

    send(owner_pid, {:term_data, :ignore, :not_a_binary})
    send(owner_pid, {:term_data, :ignore, "good-data", :replay})

    assert_receive {:terminal_payload, :data, %{data: "good-data"}}, 1_000
    refute_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 400

    :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "single arity term_data is processed exactly once" do
    info = Info.new_agent("agent-termdata-raw", workspace_id: "ws-agent-termdata")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-termdata", info, mode: :raw, session_id: "termdata-single")

    send(owner_pid, {:term_data, "abc"})

    assert_receive {:terminal_payload, :data, %{data: "abc"}}, 1_000
    refute_receive {:terminal_payload, :data, %{data: "abc"}}, 150

    :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "unexpected term_data shapes are ignored safely" do
    info =
      Info.new_agent("agent-termdata-unexpected", workspace_id: "ws-agent-termdata-unexpected")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-termdata-unexpected", info,
        mode: :raw,
        session_id: "termdata-unexpected"
      )

    monitor = Process.monitor(owner_pid)

    send(owner_pid, {:term_data, :ignore, "abc", :replay, :extra})
    refute_receive {:terminal_payload, :data, %{data: "abc"}}, 150
    refute_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 400

    :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "replay buffer truncates terminal output to bounded size" do
    info = Terminals.new_shell("ws-shell-truncate", "sid-truncate")

    parent = self()

    owner_pid = start_shell_owner("ws-shell-truncate", info)
    seed_stub_attachment(owner_pid)

    first = spawn(fn -> relay(parent, :truncate_first) end)
    register_subscriber(owner_pid, first, :raw)

    send(owner_pid, {:term_data, :ignore, String.duplicate("A", 20_000), :replay})
    send(owner_pid, {:term_data, :ignore, String.duplicate("B", 20_000), :replay})

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-shell-truncate", info,
            mode: :raw,
            session_id: "sid-truncate"
          )

        relay(parent, :truncate)
      end)

    assert_receive {:truncate, %{data: replay, replay: true}}, 1_000
    assert byte_size(replay) <= 32 * 1024

    Process.exit(first, :kill)
    Process.exit(second, :kill)
    GenServer.stop(owner_pid, :normal)
  end

  test "replay truncation honors runtime replay buffer limit configuration" do
    previous_limit = Application.get_env(:dev_ide, :terminal_replay_buffer_bytes)
    Application.put_env(:dev_ide, :terminal_replay_buffer_bytes, 6)

    try do
      info = Terminals.new_shell("ws-shell-config-truncate", "sid-config-truncate")

      parent = self()

      owner_pid = start_shell_owner("ws-shell-config-truncate", info)
      seed_stub_attachment(owner_pid)

      first = spawn(fn -> relay(parent, :config_truncate_first) end)
      register_subscriber(owner_pid, first, :raw)

      send(owner_pid, {:term_data, :ignore, "AAAAAA", :replay})
      send(owner_pid, {:term_data, :ignore, "BBBBBB", :replay})

      second =
        spawn(fn ->
          {:ok, _, _} =
            Terminals.owner_attach("ws-shell-config-truncate", info,
              mode: :raw,
              session_id: "sid-config-truncate"
            )

          relay(parent, :config_truncate)
        end)

      assert_receive {:config_truncate, %{data: replay, replay: true}}, 1_000
      assert replay == "BBBBBB"

      Process.exit(first, :kill)
      Process.exit(second, :kill)
      GenServer.stop(owner_pid, :normal)
    after
      if previous_limit == nil do
        Application.delete_env(:dev_ide, :terminal_replay_buffer_bytes)
      else
        Application.put_env(:dev_ide, :terminal_replay_buffer_bytes, previous_limit)
      end
    end
  end

  test "raw attachment opens underlying attachment once and closes it once" do
    unique = System.unique_integer([:positive])
    ws = "ws-open-close-#{unique}"
    sid = "open-close-#{unique}"
    info = Terminals.new_shell(ws, sid)

    baseline = Telemetry.count_open_attachments()

    {:ok, owner_pid, _} =
      Terminals.owner_attach(ws, info,
        mode: :raw,
        session_id: sid,
        workspace_key: ws,
        loc: {:local, "."}
      )

    assert Telemetry.count_open_attachments() == baseline + 1

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach(ws, info,
        mode: :raw,
        session_id: sid,
        workspace_key: ws,
        loc: {:local, "."}
      )

    assert Telemetry.count_open_attachments() == baseline + 1

    # Shell owners are immortal, so detach alone never stops them; stopping the
    # owner exercises the close-once accounting in terminate/2.
    assert :ok = Terminals.owner_detach(owner_pid, self())
    monitor = Process.monitor(owner_pid)
    GenServer.stop(owner_pid, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
    assert Telemetry.count_open_attachments() == baseline
  end

  test "first raw attach opens cleanly with client color seeding enabled (tmux >= 3.5)" do
    # Force the version gate open without swapping the whole adapter, so the real
    # attach path still runs against the test tmux server. Byte-level emission is
    # covered by the set_theme tests; here we prove the seed wired into the
    # attachment-open branch does not break opening. Guarded on the real binary:
    # forcing the gate open in front of an older tmux would feed the seed bytes
    # into the pane as key input (CI pins 3.7; unpinned dev hosts may not).
    if tmux_binary_at_least?({3, 5}) do
      TmuxCtl.Client.put_version_cache({3, 6})
      on_exit(&TmuxCtl.Client.reset_version_cache/0)
      assert_first_raw_attach_opens_with_seeding()
    end
  end

  defp tmux_binary_at_least?(minimum) do
    with path when is_binary(path) <- System.find_executable("tmux"),
         {out, 0} <- System.cmd(path, ["-V"], stderr_to_stdout: true),
         [_, major, minor] <- Regex.run(~r/(\d+)\.(\d+)/, out) do
      {String.to_integer(major), String.to_integer(minor)} >= minimum
    else
      _ -> false
    end
  end

  defp assert_first_raw_attach_opens_with_seeding do
    unique = System.unique_integer([:positive])
    ws = "ws-seed-#{unique}"
    sid = "seed-#{unique}"
    info = Terminals.new_shell(ws, sid)
    baseline = Telemetry.count_open_attachments()

    {:ok, owner_pid, _} =
      Terminals.owner_attach(ws, info,
        mode: :raw,
        session_id: sid,
        workspace_key: ws,
        loc: {:local, "."}
      )

    assert Telemetry.count_open_attachments() == baseline + 1
    assert Process.alive?(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, self())
    GenServer.stop(owner_pid, :normal)
  end

  test "duplicate attach by same subscriber is idempotent and does not duplicate attachment opens" do
    unique = System.unique_integer([:positive])
    ws = "ws-dupe-#{unique}"
    sid = "dupe-#{unique}"
    info = Terminals.new_shell(ws, sid)

    expected_key = {:terminal_owner, :shell, ws, sid}
    baseline = Telemetry.count_open_attachments()

    {:ok, owner_pid, _} =
      Terminals.owner_attach(ws, info,
        mode: :raw,
        session_id: sid,
        workspace_key: ws,
        loc: {:local, "."}
      )

    assert attachment_count_for(Telemetry.subscribers_per_owner(), expected_key) == 1
    assert Telemetry.count_open_attachments() == baseline + 1

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach(ws, info,
        mode: :raw,
        session_id: sid,
        workspace_key: ws,
        loc: {:local, "."}
      )

    assert attachment_count_for(Telemetry.subscribers_per_owner(), expected_key) == 1
    assert Telemetry.count_open_attachments() == baseline + 1

    monitor = Process.monitor(owner_pid)
    assert :ok = Terminals.owner_detach(owner_pid, self())
    GenServer.stop(owner_pid, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
    assert Telemetry.count_open_attachments() == baseline
  end

  test "mode transition on same subscriber keeps a single attachment and updates raw fanout state" do
    unique = System.unique_integer([:positive])
    ws = "ws-mode-transition-#{unique}"
    sid = "mode-transition-#{unique}"
    info = Terminals.new_shell(ws, sid)

    expected_key = {:terminal_owner, :shell, ws, sid}

    {:ok, owner_pid, _} =
      Terminals.owner_attach(ws, info,
        mode: :raw,
        session_id: sid,
        workspace_key: ws,
        loc: {:local, "."}
      )

    assert attachment_count_for(Telemetry.subscribers_per_owner(), expected_key) == 1
    assert Terminals.owner_subscriber_count(owner_pid) == 1

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach(ws, info,
        mode: :raw,
        session_id: sid,
        workspace_key: ws,
        loc: {:local, "."}
      )

    assert attachment_count_for(Telemetry.subscribers_per_owner(), expected_key) == 1
    assert Terminals.owner_subscriber_count(owner_pid) == 1

    send(owner_pid, {:term_data, :ignore, "governed-only-frame"})
    assert_receive {:terminal_payload, :data, %{data: "governed-only-frame"}}, 1_000
    refute_receive {:terminal_payload, :data, %{data: "governed-only-frame", replay: true}}, 150

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach(ws, info,
        mode: :raw,
        session_id: sid,
        workspace_key: ws,
        loc: {:local, "."}
      )

    assert attachment_count_for(Telemetry.subscribers_per_owner(), expected_key) == 1
    assert Terminals.owner_subscriber_count(owner_pid) == 1

    assert :ok = Terminals.owner_detach(owner_pid, self())
    monitor = Process.monitor(owner_pid)
    GenServer.stop(owner_pid, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
    assert attachment_count_for(Telemetry.subscribers_per_owner(), expected_key) == 0
  end

  test "shell output is only sent to raw subscribers" do
    unique = "shell-only-raw-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-shell-output", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-shell-output", info)

    parent = self()

    raw_subscriber =
      spawn(fn ->
        receive do
          {:terminal_payload, :data, payload} -> send(parent, {:raw_payload, payload})
        end
      end)

    :sys.replace_state(owner_pid, fn state ->
      %{state | raw_subscribers: MapSet.put(state.raw_subscribers, raw_subscriber)}
    end)

    send(owner_pid, {:term_data, :ignore, "shell-frame"})

    assert_receive {:raw_payload, payload}, 1_000
    assert payload.data == "shell-frame"

    refute_receive {:terminal_payload, :data, %{data: "shell-frame"}}, 250

    Process.exit(raw_subscriber, :kill)

    if Process.alive?(owner_pid) do
      GenServer.stop(owner_pid, :normal)
    end
  end

  test "shell raw subscriber stops receiving fanout after detach" do
    unique = "shell-detach-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-shell-switch", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-shell-switch", info)
    register_subscriber(owner_pid, self(), :raw)

    send(owner_pid, {:term_data, :ignore, "before-detach"})
    assert_receive {:terminal_payload, :data, %{data: "before-detach"}}, 500

    :ok = Terminals.owner_detach(owner_pid, self())

    send(owner_pid, {:term_data, :ignore, "after-detach"})

    refute_receive {:terminal_payload, :data, %{data: "after-detach"}}, 250

    if Process.alive?(owner_pid) do
      GenServer.stop(owner_pid, :normal)
    end
  end

  test "agent owner sends terminal data to subscribers" do
    info = Info.new_agent("agent-no-raw", workspace_id: "ws-agent-no-raw")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-no-raw", info, mode: :raw, session_id: "agent-no-raw")

    send(owner_pid, {:term_data, :ignore, "governed-only"})
    assert_receive {:terminal_payload, :data, %{data: "governed-only"}}, 1_000

    :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "GhosttyRawAdapter provides canonical raw shell bridge (PaneWorker tmux coexistence)" do
    # The adapter ensures channel raw joins (owner path) work for tmux sessions
    # that may be live from Ghostty/PaneWorker without any changes to LV side.
    alias DevIDE.Terminals.GhosttyRawAdapter

    assert {:ok, first_pid} =
             GhosttyRawAdapter.ensure_raw_shell("ws-adapter", "sid-adapter", {:local, "."})

    # Idempotent bootstrap for the same workspace/sid pair keeps a single shared
    # Session process (no extra PTY client fanout from repeated raw attach storms).
    assert {:ok, second_pid} =
             GhosttyRawAdapter.ensure_raw_shell("ws-adapter", "sid-adapter", {:local, "."})

    assert first_pid == second_pid
    assert GhosttyRawAdapter.raw_session_active?("ws-adapter", "sid-adapter") == true

    # Uses the same loc shape as LV pane workers; -A attach reuses tmux.
    Process.exit(first_pid, :normal)
  end

  test "replay payloads from owner include enriched state marker for reconnect UX" do
    info = Terminals.new_shell("ws-shell-marker", "sid-marker")

    parent = self()
    owner_pid = start_shell_owner("ws-shell-marker", info)
    seed_stub_attachment(owner_pid)

    first = spawn(fn -> relay(parent, :marker_first) end)
    register_subscriber(owner_pid, first, :raw)

    send(owner_pid, {:term_data, :ignore, "marker-data", :replay})

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-shell-marker", info, mode: :raw, session_id: "sid-marker")

        relay(parent, :marker)
      end)

    assert_receive {:marker, payload}, 1_000
    assert payload.replay == true
    assert payload.replay_frame == true
    assert payload.state_marker.kind == "replay"
    assert is_integer(payload.state_marker.ts)

    Process.exit(first, :kill)
    Process.exit(second, :kill)
    GenServer.stop(owner_pid, :normal)
  end

  test "shell raw attach requires workspace key and loc, returning invalid attachment options" do
    info = Terminals.new_shell("ws-shell-attach-opts", "sid-shell-attach-opts")

    baseline = Telemetry.count_open_attachments()

    assert {:error, :invalid_shell_attachment_opts} =
             Terminals.owner_attach(
               "ws-shell-attach-opts",
               info,
               mode: :raw,
               session_id: "shell-attach-opts"
             )

    assert Telemetry.count_open_attachments() == baseline
  end

  test "owner broadcasts terminal exit to all subscribers before stopping" do
    info = Info.new_agent("agent-exit", workspace_id: "ws-agent-exit")

    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-exit", info, mode: :raw, session_id: "agent-exit")

    monitor = Process.monitor(owner_pid)

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-agent-exit", info, mode: :raw, session_id: "agent-exit")

        send(parent, :second_attached)

        receive do
          msg ->
            send(parent, msg)
        end
      end)

    second_monitor = Process.monitor(second)
    assert_receive :second_attached, 1_000

    send(owner_pid, {:term_exit, :process_exit})
    assert_receive {:terminal_payload, :exit, :process_exit}, 1_000
    assert_receive {:terminal_payload, :exit, :process_exit}, 1_000

    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 1_000

    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 500
  end

  test "term_exit with ref payload notifies subscribers and terminates owner" do
    info = Info.new_agent("agent-term-exit-ref", workspace_id: "ws-agent-term-exit-ref")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-agent-term-exit-ref", info,
        mode: :raw,
        session_id: "term-exit-ref"
      )

    monitor = Process.monitor(owner_pid)

    send(owner_pid, {:term_exit, make_ref(), :signal})
    assert_receive {:terminal_payload, :exit, :signal}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 1_000
  end

  test "subscriber_count/1 and Terminals.owner_subscriber_count/1 return correct live count" do
    unique = "subcount-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-subcount", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-subcount", info)
    register_subscriber(owner_pid, self(), :raw)

    assert Terminals.owner_subscriber_count(owner_pid) == 1
    assert DevIDE.Terminals.SessionOwner.subscriber_count(owner_pid) == 1

    assert :ok = Terminals.owner_detach(owner_pid, self())
    # Stronger coverage: count drops to 0 immediately after detach (before stop)
    # and the GenServer handler is exercised for both growth and shrink paths.
    assert Terminals.owner_subscriber_count(owner_pid) == 0
    assert DevIDE.Terminals.SessionOwner.subscriber_count(owner_pid) == 0

    GenServer.stop(owner_pid, :normal)
  end

  test "synchronous resize from LiveTerminal does not crash owner" do
    unique = "sync-resize-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-sync-resize", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-sync-resize", info)
    register_subscriber(owner_pid, self(), :raw)

    fake_session =
      start_supervised!(%{
        id: {DevIDE.Test.FakeTerminalSession, unique},
        start:
          {GenServer, :start_link,
           [DevIDE.Test.FakeTerminalSession, {"ws-sync-resize", "sid-#{unique}", self()}, []]}
      })

    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | attachment: %DevIDE.Terminals.Attachment{
            kind: :shell,
            backend: DevIDE.Terminals.Session,
            pid: fake_session
          }
      }
    end)

    assert :ok = GenServer.call(owner_pid, {:resize, 197, 56})
    assert_receive {:fake_session_resize, ^fake_session, 197, 56}
    assert Process.alive?(owner_pid)

    GenServer.stop(owner_pid, :normal)
  end

  test "viewer-tagged resizes size the shared PTY to the focused viewer" do
    unique = "focus-resize-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-focus", "sid-#{unique}")

    # Register the test process as a raw subscriber on a backend-less shell owner,
    # binding no workspace_key so the owner skips the best-effort tmux subprocess.
    owner_pid = start_shell_owner("ws-focus", info)
    register_subscriber(owner_pid, self(), :raw)

    fake_session =
      start_supervised!(%{
        id: {DevIDE.Test.FakeTerminalSession, unique},
        start:
          {GenServer, :start_link,
           [DevIDE.Test.FakeTerminalSession, {"ws-focus", "sid-#{unique}", self()}, []]}
      })

    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | attachment: %DevIDE.Terminals.Attachment{
            kind: :shell,
            backend: DevIDE.Terminals.Session,
            pid: fake_session
          }
      }
    end)

    big_viewer = spawn(fn -> Process.sleep(:infinity) end)

    # Wide viewer reports first. With no viewer active yet, the owner sizes to the
    # LARGEST requested size so a single/just-attached viewer always fits.
    GenServer.cast(owner_pid, {:resize, big_viewer, 200, 60})
    assert_receive {:fake_session_resize, ^fake_session, 200, 60}

    # A narrow background viewer joins. THE FIX: while nobody is focused, a smaller
    # viewer must NOT shrink the shared PTY — the largest still wins (no resize).
    GenServer.cast(owner_pid, {:resize, self(), 80, 24})
    refute_receive {:fake_session_resize, ^fake_session, _, _}, 100

    # The narrow viewer becomes the focused/active one → the PTY follows it down.
    GenServer.cast(owner_pid, {:viewer_active, self(), true})
    assert_receive {:fake_session_resize, ^fake_session, 80, 24}

    # The wide viewer is focused more recently → it wins the recency tiebreak.
    GenServer.cast(owner_pid, {:viewer_active, big_viewer, true})
    assert_receive {:fake_session_resize, ^fake_session, 200, 60}

    # A no-op (same applied size) must not re-resize the attachment.
    GenServer.cast(owner_pid, {:resize, big_viewer, 200, 60})
    refute_receive {:fake_session_resize, ^fake_session, _, _}, 100

    # The wide viewer goes inactive → the only remaining active viewer (narrow) wins.
    GenServer.cast(owner_pid, {:viewer_active, big_viewer, false})
    assert_receive {:fake_session_resize, ^fake_session, 80, 24}

    # Both inactive → fall back to the largest requested size.
    GenServer.cast(owner_pid, {:viewer_active, self(), false})
    assert_receive {:fake_session_resize, ^fake_session, 200, 60}

    # The narrow viewer (this process) re-focuses then detaches; the wide one
    # already holds the size, so detach emits no further resize.
    GenServer.cast(owner_pid, {:viewer_active, self(), true})
    assert_receive {:fake_session_resize, ^fake_session, 80, 24}
    :ok = GenServer.call(owner_pid, {:detach, self()})
    assert_receive {:fake_session_resize, ^fake_session, 200, 60}

    Process.exit(big_viewer, :kill)
  end

  test "authoritative size changes broadcast terminal_owner_size to subscribers" do
    unique = "owner-size-broadcast-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-size-broadcast", "sid-#{unique}")
    owner_pid = start_shell_owner("ws-size-broadcast", info)
    subscriber = register_subscriber(owner_pid, self(), :raw)

    GenServer.cast(owner_pid, {:resize, subscriber, 140, 42})
    assert_receive {:terminal_owner_size, 140, 42}, 1_000

    GenServer.stop(owner_pid, :normal)
  end

  test "tmux drift guard re-asserts the authoritative size when the window moved" do
    swap_in_fake_tmux_adapter()

    unique = "drift-guard-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-drift-guard", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-drift-guard", info)
    register_subscriber(owner_pid, self(), :raw)

    :sys.replace_state(owner_pid, fn state ->
      %{state | workspace_key: "ws-drift-guard", applied_size: {120, 40}}
    end)

    TmuxCtl.Test.FakeState.put(:fake_tmux_window_sizes, %{
      "devide_ws-drift-guard_sid-#{unique}" => {80, 24}
    })

    send(owner_pid, :tmux_drift_check)

    assert_receive {:fake_tmux_resize_window, session, 120, 40}
    assert_receive {:fake_tmux_refresh_client, ^session}

    GenServer.stop(owner_pid, :normal)
  end

  test "a fitted size flapping back to the bootstrap default emits a breadcrumb" do
    # The PR #148 incident signature: the same viewer reports a real fitted
    # size, then 80x24 (the component/vendor dataset default) moments later —
    # a stale deferred "ready" clobbering the fit. That must leave a
    # warning + telemetry trail instead of being silently applied.
    swap_in_fake_tmux_adapter()

    unique = "size-flap-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-size-flap", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-size-flap", info)
    register_subscriber(owner_pid, self(), :raw)
    :sys.replace_state(owner_pid, fn state -> %{state | workspace_key: "ws-size-flap"} end)

    :telemetry_test.attach_event_handlers(self(), [
      [:dev_ide, :terminals, :owner, :size_flap]
    ])

    # Bootstrap default as the FIRST report is normal (fresh mount) — no flap.
    GenServer.cast(owner_pid, {:resize, self(), 80, 24})
    # A fitted size, then a non-default change — normal drag/refit — no flap.
    GenServer.cast(owner_pid, {:resize, self(), 228, 117})
    GenServer.cast(owner_pid, {:resize, self(), 100, 30})
    _ = :sys.get_state(owner_pid)
    refute_received {[:dev_ide, :terminals, :owner, :size_flap], _, _, _}

    # Fitted size immediately clobbered by the bootstrap default — the bug.
    GenServer.cast(owner_pid, {:resize, self(), 228, 117})
    GenServer.cast(owner_pid, {:resize, self(), 80, 24})

    assert_receive {[:dev_ide, :terminals, :owner, :size_flap], _ref, %{elapsed_ms: _},
                    %{from: {228, 117}, to: {80, 24}}}

    GenServer.stop(owner_pid, :normal)
  end

  test "a sustained drift-re-assert streak escalates to a fight warning" do
    # A re-assert that never sticks means another writer (stale draining
    # instance, duplicate owner, external client) is fighting this owner.
    swap_in_fake_tmux_adapter()

    unique = "drift-fight-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-drift-fight", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-drift-fight", info)
    register_subscriber(owner_pid, self(), :raw)

    :sys.replace_state(owner_pid, fn state ->
      %{state | workspace_key: "ws-drift-fight", applied_size: {120, 40}}
    end)

    session = "devide_ws-drift-fight_sid-#{unique}"
    TmuxCtl.Test.FakeState.put(:fake_tmux_window_sizes, %{session => {80, 24}})

    :telemetry_test.attach_event_handlers(self(), [
      [:dev_ide, :terminals, :owner, :drift_fight]
    ])

    # Play the fighting writer: after every re-assert, knock the window back
    # to 80x24 before the owner's next drift tick (the fake adapter's
    # resize_window records the re-asserted size, so a one-shot mismatch
    # would settle and reset the streak — exactly what a real fight doesn't
    # do). The re-assert runs in an async task; wait for its two adapter
    # calls and the owner clearing its single-flight slot before poisoning
    # the size again, or the task's own write would race ours.
    for n <- 1..4 do
      if n == 4 do
        refute_received {[:dev_ide, :terminals, :owner, :drift_fight], _, _, _}
      end

      TmuxCtl.Test.FakeState.put(:fake_tmux_window_sizes, %{session => {80, 24}})
      send(owner_pid, :tmux_drift_check)
      assert_receive {:fake_tmux_resize_window, ^session, 120, 40}
      assert_receive {:fake_tmux_refresh_client, ^session}
      await_resize_settled(owner_pid)
    end

    assert_receive {[:dev_ide, :terminals, :owner, :drift_fight], _ref, %{streak: 4},
                    %{applied: {120, 40}, actual: {80, 24}}}

    # The window settling at the applied size resets the streak.
    TmuxCtl.Test.FakeState.put(:fake_tmux_window_sizes, %{session => {120, 40}})
    send(owner_pid, :tmux_drift_check)
    assert %{tmux_drift_streak: 0} = :sys.get_state(owner_pid)

    GenServer.stop(owner_pid, :normal)
  end

  @tag :tmux_timeout
  test "owner stays responsive when tmux window_size hangs on drift check" do
    swap_in_fake_tmux_adapter()

    prev_timeout = Application.get_env(:dev_ide, :tmux_window_size_timeout_ms)
    Application.put_env(:dev_ide, :tmux_window_size_timeout_ms, 50)

    on_exit(fn ->
      if prev_timeout do
        Application.put_env(:dev_ide, :tmux_window_size_timeout_ms, prev_timeout)
      else
        Application.delete_env(:dev_ide, :tmux_window_size_timeout_ms)
      end

      TmuxCtl.Test.FakeState.delete(:fake_tmux_window_size_hang)
    end)

    unique = "tmux-timeout-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-tmux-timeout", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-tmux-timeout", info)
    register_subscriber(owner_pid, self(), :raw)

    :sys.replace_state(owner_pid, fn state ->
      %{state | workspace_key: "ws-tmux-timeout", applied_size: {120, 40}}
    end)

    TmuxCtl.Test.FakeState.put(:fake_tmux_window_size_hang, true)

    send(owner_pid, :tmux_drift_check)

    assert :sys.get_state(owner_pid, 500)

    GenServer.stop(owner_pid, :normal)
  end

  test "a draining instance stops asserting sizes onto shared tmux state" do
    # An old release's owners outlive the deploy handoff while stale browser
    # tabs hold connections; if they keep re-asserting their (stale)
    # applied_size, the old and new instances ping-pong resize-window against
    # each other every drift tick. Once draining, drift checks and viewer
    # resizes must not write to tmux.
    swap_in_fake_tmux_adapter()

    unique = "drain-guard-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-drain-guard", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-drain-guard", info)
    register_subscriber(owner_pid, self(), :raw)

    :sys.replace_state(owner_pid, fn state ->
      %{state | workspace_key: "ws-drain-guard", applied_size: {120, 40}}
    end)

    TmuxCtl.Test.FakeState.put(:fake_tmux_window_sizes, %{
      "devide_ws-drain-guard_sid-#{unique}" => {80, 24}
    })

    :ok = DevIDE.Deployment.Drain.start_drain(1)
    on_exit(fn -> DevIDE.Deployment.Drain.reset_for_test!() end)

    send(owner_pid, :tmux_drift_check)
    refute_receive {:fake_tmux_resize_window, _, _, _}, 200

    # A viewer resize arriving mid-drain must also stay off shared tmux.
    GenServer.cast(owner_pid, {:viewer_active, self(), true})
    GenServer.cast(owner_pid, {:resize, self(), 130, 41})
    refute_receive {:fake_tmux_resize_window, _, _, _}, 200

    GenServer.stop(owner_pid, :normal)
  end

  test "tmux resizes are single-flight, coalesce to latest, and end with a refresh heal" do
    swap_in_fake_tmux_adapter()

    unique = "single-flight-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-single-flight", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-single-flight", info)
    register_subscriber(owner_pid, self(), :raw)

    :sys.replace_state(owner_pid, fn state -> %{state | workspace_key: "ws-single-flight"} end)

    # Focused viewer drives the size → one resize task runs and ends with the
    # refresh-client heal.
    GenServer.cast(owner_pid, {:viewer_active, self(), true})
    GenServer.cast(owner_pid, {:resize, self(), 120, 40})
    assert_receive {:fake_tmux_resize_window, session, 120, 40}
    assert_receive {:fake_tmux_refresh_client, ^session}

    # Fabricate an in-flight resize task (ref created inside the owner so its
    # demonitor is legal). Sizes arriving meanwhile must queue, latest-wins,
    # and must NOT spawn concurrent resize-window subprocesses.
    :sys.replace_state(owner_pid, fn state ->
      %{state | tmux_resize: %{ref: make_ref(), size: {120, 40}}}
    end)

    %{tmux_resize: %{ref: in_flight_ref}} = :sys.get_state(owner_pid)

    GenServer.cast(owner_pid, {:resize, self(), 130, 41})
    GenServer.cast(owner_pid, {:resize, self(), 140, 42})
    refute_receive {:fake_tmux_resize_window, _, _, _}, 100

    # In-flight task completes → exactly one follow-up resize at the LATEST
    # queued size, then the heal.
    send(owner_pid, {in_flight_ref, :ok})
    assert_receive {:fake_tmux_resize_window, ^session, 140, 42}
    assert_receive {:fake_tmux_refresh_client, ^session}
    refute_receive {:fake_tmux_resize_window, _, _, _}, 100

    GenServer.stop(owner_pid, :normal)
  end

  test "raw attach replay is followed by a tmux refresh-client heal" do
    swap_in_fake_tmux_adapter()

    unique = "replay-heal-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-replay-heal", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-replay-heal", info)
    seed_stub_attachment(owner_pid)

    :sys.replace_state(owner_pid, fn state ->
      %{state | workspace_key: "ws-replay-heal", replay_buffer: "\e[2Jretained tail"}
    end)

    assert {:ok, _payload} = GenServer.call(owner_pid, {:attach, self(), :raw, []})

    # Replay lands first (synchronously from the attach), then tmux is asked to
    # repaint the authoritative screen over it.
    assert_receive {:terminal_payload, :data, %{replay: true}}
    assert_receive {:fake_tmux_refresh_client, session} when is_binary(session)

    GenServer.stop(owner_pid, :normal)
  end

  test "untagged direct resize cannot condense the PTY under viewer-reported sizes" do
    unique = "direct-resize-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-direct-resize", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-direct-resize", info)
    register_subscriber(owner_pid, self(), :raw)

    fake_session =
      start_supervised!(%{
        id: {DevIDE.Test.FakeTerminalSession, unique},
        start:
          {GenServer, :start_link,
           [DevIDE.Test.FakeTerminalSession, {"ws-direct-resize", "sid-#{unique}", self()}, []]}
      })

    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | attachment: %DevIDE.Terminals.Attachment{
            kind: :shell,
            backend: DevIDE.Terminals.Session,
            pid: fake_session
          }
      }
    end)

    # The operator's viewer reports its size and focus; the policy applies it.
    GenServer.cast(owner_pid, {:resize, self(), 210, 51})
    assert_receive {:fake_session_resize, ^fake_session, 210, 51}
    GenServer.cast(owner_pid, {:viewer_active, self(), true})

    # A rogue untagged resize (Ghostty.PTY-shaped caller — historically the
    # GhosttyTerminalComponent resize handler relaying ANY viewer's
    # ResizeObserver event) must NOT condense the shared PTY: the policy owns
    # the size while viewer sizes are on record.
    assert :ok = GenServer.call(owner_pid, {:resize, 80, 40})
    refute_receive {:fake_session_resize, ^fake_session, 80, 40}, 100

    # The policy still self-corrects if applied_size drifts from the
    # attachment: a later viewer report converges back to the focused size.
    GenServer.cast(owner_pid, {:resize, self(), 210, 51})
    refute_receive {:fake_session_resize, ^fake_session, _, _}, 100

    GenServer.stop(owner_pid, :normal)
  end

  test "later attach without context opts does not clobber workspace_key/loc binding" do
    info = Terminals.new_shell("ws-bind-keep", "shell-bind-keep")

    # The attachment context (workspace_key/loc/host_id) is bound during attach
    # before the backend opens. We pre-bind it directly (a headless shell PTY
    # cannot be opened in tests) and then verify a later opts-less attach does
    # not clobber it — the historical bug overwrote the binding with nil.
    owner_pid = start_shell_owner("ws-bind-keep", info)

    # Seed bindings and a stub attachment so the re-attach reuses it instead of
    # opening a real PTY (which a headless test cannot do).
    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | workspace_key: "ws-bind-keep",
          loc: {:cwd, "/tmp/ws-bind-keep"},
          host_id: "local",
          attachment: %DevIDE.Terminals.Attachment{
            kind: :shell,
            backend: DevIDE.Terminals.Session,
            pid: self()
          }
      }
    end)

    # A re-attach without context opts must not bind nil over the existing
    # values; binding runs before (and independent of) the backend.
    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-bind-keep", info,
        mode: :raw,
        session_id: "shell-bind-keep"
      )

    state = :sys.get_state(owner_pid)
    assert state.workspace_key == "ws-bind-keep"
    assert state.loc == {:cwd, "/tmp/ws-bind-keep"}
    assert state.host_id == "local"

    GenServer.stop(owner_pid, :normal)
  end

  test "conflicting attach context keeps the existing binding" do
    info = Terminals.new_shell("ws-bind-conflict", "shell-bind-conflict")

    owner_pid = start_shell_owner("ws-bind-conflict", info)

    # Seed the original binding plus a stub attachment so the conflicting attach
    # reuses it rather than opening a real PTY.
    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | workspace_key: "ws-bind-conflict",
          loc: {:cwd, "/tmp/original"},
          attachment: %DevIDE.Terminals.Attachment{
            kind: :shell,
            backend: DevIDE.Terminals.Session,
            pid: self()
          }
      }
    end)

    # Attaching with a conflicting loc must keep the original binding;
    # bind_attachment_context refuses to overwrite a live binding.
    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-bind-conflict", info,
        mode: :raw,
        session_id: "shell-bind-conflict",
        loc: {:cwd, "/tmp/other"}
      )

    state = :sys.get_state(owner_pid)
    assert state.loc == {:cwd, "/tmp/original"}

    GenServer.stop(owner_pid, :normal)
  end

  test "raw attach replays the authoritative Session buffer when an attachment exists" do
    unique = System.unique_integer([:positive])
    sid = "sid-snap-#{unique}"
    info = Terminals.new_shell("ws-snap", sid)

    owner_pid = start_shell_owner("ws-snap", info)

    {:ok, fake_session} =
      DevIDE.Test.FakeTerminalSession.ensure_started("ws-snap", sid, {:fake, self()})

    # Output produced while NO raw subscriber was attached — the owner's
    # replay_buffer never saw it, but the Session buffer (authoritative) did.
    :ok =
      DevIDE.Test.FakeTerminalSession.seed_buffer(
        fake_session,
        "pre-attach-output\e[3;7Rtail"
      )

    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | attachment: %DevIDE.Terminals.Attachment{
            kind: :shell,
            backend: DevIDE.Terminals.Session,
            pid: fake_session,
            cols: 120,
            rows: 40
          }
      }
    end)

    {:ok, ^owner_pid, %{mode: "raw"}} =
      Terminals.owner_attach("ws-snap", info, mode: :raw, session_id: sid)

    assert_receive {:terminal_payload, :data, %{data: data, replay: true}}, 1_500
    assert data == "pre-attach-outputtail"
    refute String.contains?(data, "\e[")

    GenServer.stop(owner_pid, :normal)
  end

  describe "single-responder terminal query responses" do
    test "only the current responder's query response reaches the PTY" do
      {owner_pid, fake_session} = start_owner_with_fake_session("query-responder")

      other = spawn(fn -> Process.sleep(:infinity) end)
      register_subscriber(owner_pid, self(), :raw)
      register_subscriber(owner_pid, other, :raw)

      # This viewer is focused → it is the responder.
      GenServer.cast(owner_pid, {:viewer_active, self(), true})

      # The non-responder's answer is dropped.
      GenServer.cast(owner_pid, {:query_response, other, "\e[10;20R"})
      refute_receive {:fake_session_input, ^fake_session, _}, 100

      # The responder's answer is forwarded, and CPR content passes unmodified.
      GenServer.cast(owner_pid, {:query_response, self(), "\e[10;20R"})
      assert_receive {:fake_session_input, ^fake_session, "\e[10;20R"}, 1_000

      Process.exit(other, :kill)
      GenServer.stop(owner_pid, :normal)
    end

    test "responder detach lets another subscriber's responses pass" do
      {owner_pid, fake_session} = start_owner_with_fake_session("query-detach")

      other = spawn(fn -> Process.sleep(:infinity) end)
      register_subscriber(owner_pid, self(), :raw)
      register_subscriber(owner_pid, other, :raw)

      GenServer.cast(owner_pid, {:viewer_active, self(), true})
      GenServer.cast(owner_pid, {:query_response, self(), "\e[10;20R"})
      assert_receive {:fake_session_input, ^fake_session, "\e[10;20R"}, 1_000

      # The other viewer is not the responder while this one is attached.
      GenServer.cast(owner_pid, {:query_response, other, "\e[?62;22c"})
      refute_receive {:fake_session_input, ^fake_session, _}, 100

      # Responder leaves → the remaining subscriber self-heals into responder.
      :ok = GenServer.call(owner_pid, {:detach, self()})
      GenServer.cast(owner_pid, {:query_response, other, "\e[?62;22c"})
      assert_receive {:fake_session_input, ^fake_session, "\e[?62;22c"}, 1_000

      Process.exit(other, :kill)
      GenServer.stop(owner_pid, :normal)
    end

    test "set_active flips the responder to the most recently active viewer" do
      {owner_pid, fake_session} = start_owner_with_fake_session("query-flip")

      other = spawn(fn -> Process.sleep(:infinity) end)
      register_subscriber(owner_pid, self(), :raw)
      register_subscriber(owner_pid, other, :raw)

      GenServer.cast(owner_pid, {:viewer_active, self(), true})
      GenServer.cast(owner_pid, {:query_response, self(), "\e[10;20R"})
      assert_receive {:fake_session_input, ^fake_session, "\e[10;20R"}, 1_000

      # The other viewer becomes active more recently → it wins the recency rule.
      GenServer.cast(owner_pid, {:viewer_active, other, true})
      GenServer.cast(owner_pid, {:query_response, self(), "\e[?62;22c"})
      refute_receive {:fake_session_input, ^fake_session, _}, 100

      GenServer.cast(owner_pid, {:query_response, other, "\e[?62;22c"})
      assert_receive {:fake_session_input, ^fake_session, "\e[?62;22c"}, 1_000

      Process.exit(other, :kill)
      GenServer.stop(owner_pid, :normal)
    end

    test "reported size matching the applied PTY size elects the responder when nobody is active" do
      {owner_pid, fake_session} = start_owner_with_fake_session("query-size")

      other = spawn(fn -> Process.sleep(:infinity) end)
      register_subscriber(owner_pid, self(), :raw)
      register_subscriber(owner_pid, other, :raw)

      # Nobody focused: the largest size wins the PTY, and its viewer answers.
      GenServer.cast(owner_pid, {:resize, other, 80, 24})
      assert_receive {:fake_session_resize, ^fake_session, 80, 24}, 1_000
      GenServer.cast(owner_pid, {:resize, self(), 200, 60})
      assert_receive {:fake_session_resize, ^fake_session, 200, 60}, 1_000

      GenServer.cast(owner_pid, {:query_response, other, "\e[10;20R"})
      refute_receive {:fake_session_input, ^fake_session, _}, 100

      GenServer.cast(owner_pid, {:query_response, self(), "\e[10;20R"})
      assert_receive {:fake_session_input, ^fake_session, "\e[10;20R"}, 1_000

      Process.exit(other, :kill)
      GenServer.stop(owner_pid, :normal)
    end

    test "same-class responses within the duplicate window collapse to one" do
      {owner_pid, fake_session} = start_owner_with_fake_session("query-dedupe")

      register_subscriber(owner_pid, self(), :raw)
      GenServer.cast(owner_pid, {:viewer_active, self(), true})

      GenServer.cast(owner_pid, {:query_response, self(), "\e[10;20R"})
      GenServer.cast(owner_pid, {:query_response, self(), "\e[11;21R"})
      assert_receive {:fake_session_input, ^fake_session, "\e[10;20R"}, 1_000
      refute_receive {:fake_session_input, ^fake_session, _}, 150

      # A different class is not a duplicate of the CPR and still passes.
      GenServer.cast(owner_pid, {:query_response, self(), "\e[?62;22c"})
      assert_receive {:fake_session_input, ^fake_session, "\e[?62;22c"}, 1_000

      GenServer.stop(owner_pid, :normal)
    end

    test "OSC color responses are rewritten with the session theme; set_theme flips it" do
      {owner_pid, fake_session} = start_owner_with_fake_session("query-theme")

      register_subscriber(owner_pid, self(), :raw)
      GenServer.cast(owner_pid, {:viewer_active, self(), true})

      # Default session theme: dark catppuccin (mocha bg #1e1e2e).
      GenServer.cast(owner_pid, {:query_response, self(), "\e]11;#000000\a"})
      assert_receive {:fake_session_input, ^fake_session, "\e]11;rgb:1e1e/1e1e/2e2e\a"}, 1_000

      DevIDE.Terminals.SessionOwner.set_theme(owner_pid, :light, "catppuccin")

      # Outwait the same-class duplicate window so the flip is observable.
      Process.sleep(150)

      # Latte bg #eff1f5 — the answering viewer's own theme no longer matters.
      GenServer.cast(owner_pid, {:query_response, self(), "\e]11;#000000\a"})
      assert_receive {:fake_session_input, ^fake_session, "\e]11;rgb:efef/f1f1/f5f5\a"}, 1_000

      GenServer.stop(owner_pid, :normal)
    end

    test "set_theme reports client fg/bg and 997 theme to tmux >= 3.6 on a real change" do
      swap_in_fake_tmux_adapter()
      set_fake_tmux_version({3, 6})
      {owner_pid, fake_session} = start_owner_with_fake_session("theme-report")

      # Default session theme is dark catppuccin, so :light is a real change.
      DevIDE.Terminals.SessionOwner.set_theme(owner_pid, :light, "catppuccin")

      expected =
        DevIDE.Terminals.Theme.client_color_reports(
          DevIDE.Terminals.Theme.builtin_preset(:light, "catppuccin")
        ) <>
          DevIDE.Terminals.Theme.client_theme_report(:light)

      assert_receive {:fake_session_input, ^fake_session, ^expected}, 1_000

      GenServer.stop(owner_pid, :normal)
    end

    test "set_theme reports OSC only on tmux 3.5" do
      swap_in_fake_tmux_adapter()
      set_fake_tmux_version({3, 5})
      {owner_pid, fake_session} = start_owner_with_fake_session("theme-report-35")

      DevIDE.Terminals.SessionOwner.set_theme(owner_pid, :light, "catppuccin")

      expected =
        DevIDE.Terminals.Theme.client_color_reports(
          DevIDE.Terminals.Theme.builtin_preset(:light, "catppuccin")
        )

      assert_receive {:fake_session_input, ^fake_session, ^expected}, 1_000
      refute String.ends_with?(expected, "\e[?997;2n")

      GenServer.stop(owner_pid, :normal)
    end

    test "forwarded 997 theme reports are rewritten to the session scheme on tmux >= 3.6" do
      swap_in_fake_tmux_adapter()
      set_fake_tmux_version({3, 6})
      {owner_pid, fake_session} = start_owner_with_fake_session("theme-report-rewrite")

      register_subscriber(owner_pid, self(), :raw)
      GenServer.cast(owner_pid, {:viewer_active, self(), true})

      GenServer.cast(owner_pid, {:query_response, self(), "\e[?997;1n"})
      assert_receive {:fake_session_input, ^fake_session, "\e[?997;1n"}, 1_000

      DevIDE.Terminals.SessionOwner.set_theme(owner_pid, :light, "catppuccin")
      Process.sleep(150)

      GenServer.cast(owner_pid, {:query_response, self(), "\e[?997;1n"})
      assert_receive {:fake_session_input, ^fake_session, "\e[?997;2n"}, 1_000

      GenServer.stop(owner_pid, :normal)
    end

    test "incoming 997 theme reports are dropped on tmux < 3.6" do
      swap_in_fake_tmux_adapter()
      set_fake_tmux_version({3, 5})
      {owner_pid, fake_session} = start_owner_with_fake_session("theme-report-drop")

      register_subscriber(owner_pid, self(), :raw)
      GenServer.cast(owner_pid, {:viewer_active, self(), true})
      GenServer.cast(owner_pid, {:query_response, self(), "\e[?997;1n"})

      refute_receive {:fake_session_input, ^fake_session, _}, 200

      GenServer.stop(owner_pid, :normal)
    end

    test "fresh attach seeds client colors on tmux >= 3.6" do
      swap_in_fake_tmux_adapter()
      set_fake_tmux_version({3, 6})
      {owner_pid, fake_session} = start_owner_with_fake_session("fresh-seed")

      expected =
        DevIDE.Terminals.Theme.client_color_reports(
          DevIDE.Terminals.Theme.builtin_preset(:dark, "catppuccin")
        ) <>
          DevIDE.Terminals.Theme.client_theme_report(:dark)

      Application.put_env(:dev_ide, :test_shell_attachment_pid, fake_session)

      on_exit(fn -> Application.delete_env(:dev_ide, :test_shell_attachment_pid) end)

      :sys.replace_state(owner_pid, fn state -> %{state | attachment: nil} end)

      assert {:ok, _} =
               GenServer.call(
                 owner_pid,
                 {:attach, self(), :raw,
                  workspace_key: "ws-fresh-seed", loc: {:local, System.tmp_dir!()}}
               )

      assert_receive {:fake_session_input, ^fake_session, ^expected}, 1_000

      GenServer.stop(owner_pid, :normal)
    end

    test "set_theme does not report client colors on tmux <= 3.4" do
      swap_in_fake_tmux_adapter()
      set_fake_tmux_version({3, 4})
      {owner_pid, fake_session} = start_owner_with_fake_session("theme-no-report")

      DevIDE.Terminals.SessionOwner.set_theme(owner_pid, :light, "catppuccin")

      refute_receive {:fake_session_input, ^fake_session, _}, 200

      GenServer.stop(owner_pid, :normal)
    end

    test "set_theme does not report when scheme and preset are unchanged" do
      swap_in_fake_tmux_adapter()
      set_fake_tmux_version({3, 6})
      {owner_pid, fake_session} = start_owner_with_fake_session("theme-unchanged")

      # Matches the owner's default theme, so nothing changed.
      DevIDE.Terminals.SessionOwner.set_theme(owner_pid, :dark, "catppuccin")

      refute_receive {:fake_session_input, ^fake_session, _}, 200

      GenServer.stop(owner_pid, :normal)
    end
  end

  test "raw replay strips stale OSC color queries but keeps set-forms" do
    info = Terminals.new_shell("ws-shell-osc-replay", "sid-osc-replay")

    owner_pid = start_shell_owner("ws-shell-osc-replay", info)
    seed_stub_attachment(owner_pid)

    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | replay_buffer:
            "before\e]11;?\a\e]10;?\e\\\e]4;7;?\a\e]11;#112233\amiddle\e]4;1;#f38ba8\aafter"
      }
    end)

    assert {:ok, _payload} = GenServer.call(owner_pid, {:attach, self(), :raw, []})

    assert_receive {:terminal_payload, :data, %{replay: true, data: data}}, 1_000
    assert data == "before\e]11;#112233\amiddle\e]4;1;#f38ba8\aafter"

    GenServer.stop(owner_pid, :normal)
  end

  # Raw-only: a shell raw attach requires workspace_key + loc to open a PTY
  # backend, which is not available headlessly. These helpers start a shell
  # owner process directly (no backend) and register subscribers by hand so the
  # tests can exercise subscriber bookkeeping / fanout / lifecycle without a PTY.
  # Route the owner's best-effort tmux subprocess calls (resize-window /
  # apply-defaults / refresh-client) to the fake adapter and deliver its
  # breadcrumb messages to this test process. Restored on exit.
  defp swap_in_fake_tmux_adapter do
    prev_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_pid = TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    on_exit(fn ->
      if prev_adapter do
        Application.put_env(:dev_ide, :tmux_adapter, prev_adapter)
      else
        Application.delete_env(:dev_ide, :tmux_adapter)
      end

      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, prev_pid)
    end)

    :ok
  end

  # Drives the version the fake tmux adapter reports, gating the client color
  # reports emitted on scheme/preset change.
  defp set_fake_tmux_version(version) do
    prev = TmuxCtl.Test.FakeState.get(:fake_tmux_server_version)
    TmuxCtl.Test.FakeState.put(:fake_tmux_server_version, version)
    on_exit(fn -> TmuxCtl.Test.FakeState.put(:fake_tmux_server_version, prev) end)
    :ok
  end

  describe "content generation events" do
    test "live output bumps gen, stamps payloads, and emits a session event" do
      info = Terminals.new_shell("ws-gen-events", "sid-gen-1")
      owner_pid = start_shell_owner("ws-gen-events", info)
      register_subscriber(owner_pid, self(), :raw)
      assert :ok = SessionEvents.subscribe("ws-gen-events", "sid-gen-1")

      send(owner_pid, {:term_data, "hello"})

      assert_receive {:terminal_payload, :data, %{data: "hello", gen: 1}}

      assert_receive {:terminal_session_event,
                      %{type: :output, workspace_id: "ws-gen-events", sid: "sid-gen-1", gen: 1}},
                     1_000

      GenServer.stop(owner_pid, :normal)
    end

    test "a burst collapses to one event carrying the final generation" do
      info = Terminals.new_shell("ws-gen-burst", "sid-gen-2")
      owner_pid = start_shell_owner("ws-gen-burst", info)
      assert :ok = SessionEvents.subscribe("ws-gen-burst", "sid-gen-2")

      send(owner_pid, {:term_data, "a"})
      send(owner_pid, {:term_data, "b"})
      send(owner_pid, {:term_data, "c"})

      assert_receive {:terminal_session_event, %{gen: 3}}, 1_000
      refute_receive {:terminal_session_event, _}, 100

      GenServer.stop(owner_pid, :normal)
    end

    test "replay chunks never bump the generation" do
      info = Terminals.new_shell("ws-gen-replay", "sid-gen-3")
      owner_pid = start_shell_owner("ws-gen-replay", info)
      assert :ok = SessionEvents.subscribe("ws-gen-replay", "sid-gen-3")

      send(owner_pid, {:term_data, make_ref(), "old-bytes", :replay})
      refute_receive {:terminal_session_event, _}, 100

      send(owner_pid, {:term_data, "fresh"})
      assert_receive {:terminal_session_event, %{gen: 1}}, 1_000

      GenServer.stop(owner_pid, :normal)
    end
  end

  describe "OSC 133 command tracking" do
    setup do
      CommandLog.reset!()
      :ok
    end

    test "live shell output is accumulated into command records" do
      info = Terminals.new_shell("ws-cmd-log", "sid-cmd-log")
      owner_pid = start_shell_owner("ws-cmd-log", info)

      send(owner_pid, {:term_data, "\e]7;file://host/tmp/devide\a"})
      send(owner_pid, {:term_data, "\e]133;B;mix test\a"})
      send(owner_pid, {:term_data, "running\n"})
      send(owner_pid, {:term_data, "FAILED token=super-secret\n\e]133;D;1\a"})
      _ = :sys.get_state(owner_pid)

      assert [command] = CommandLog.list("ws-cmd-log", "sid-cmd-log")
      assert command.command == "mix test"
      assert command.cwd == "/tmp/devide"
      assert command.exit_status == 1
      assert command.output == "running\nFAILED token=[REDACTED]\n"
      assert command.gen_range == {2, 4}
      refute command.output_truncated?

      GenServer.stop(owner_pid, :normal)
    end

    test "a full A/B/C/D prompt cycle yields one record without the input echo" do
      info = Terminals.new_shell("ws-cmd-cycle", "sid-cmd-cycle")
      owner_pid = start_shell_owner("ws-cmd-cycle", info)

      send(owner_pid, {:term_data, "\e]133;A\a$ "})
      send(owner_pid, {:term_data, "\e]133;B;mix test\a"})
      send(owner_pid, {:term_data, "mix test\r\n"})
      send(owner_pid, {:term_data, "\e]133;C\a"})
      send(owner_pid, {:term_data, "1 test, 0 failures\n\e]133;D;0\a"})
      _ = :sys.get_state(owner_pid)

      assert [command] = CommandLog.list("ws-cmd-cycle", "sid-cmd-cycle")
      assert command.command == "mix test"
      assert command.exit_status == 0
      assert command.output == "1 test, 0 failures\n"

      GenServer.stop(owner_pid, :normal)
    end

    test "replay chunks do not create command records or bump command sequence" do
      info = Terminals.new_shell("ws-cmd-replay", "sid-cmd-replay")
      owner_pid = start_shell_owner("ws-cmd-replay", info)

      send(owner_pid, {:term_data, make_ref(), "\e]133;B;old\aold\e]133;D;0\a", :replay})
      assert [] = CommandLog.list("ws-cmd-replay", "sid-cmd-replay")

      send(owner_pid, {:term_data, "\e]133;B;new\a"})
      send(owner_pid, {:term_data, "new-output\e]133;D;0\a"})
      _ = :sys.get_state(owner_pid)

      assert [%{seq: 1, command: "new", output: "new-output"}] =
               CommandLog.list("ws-cmd-replay", "sid-cmd-replay")

      GenServer.stop(owner_pid, :normal)
    end
  end

  # Backend-less shell owner + fake Session attachment: forwarded query
  # responses surface as {:fake_session_input, pid, data} breadcrumbs and
  # resizes as {:fake_session_resize, pid, cols, rows}.
  defp start_owner_with_fake_session(tag) do
    unique = "#{tag}-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-#{tag}", "sid-#{unique}")

    owner_pid = start_shell_owner("ws-#{tag}", info)

    fake_session =
      start_supervised!(%{
        id: {DevIDE.Test.FakeTerminalSession, unique},
        start:
          {GenServer, :start_link,
           [DevIDE.Test.FakeTerminalSession, {"ws-#{tag}", "sid-#{unique}", self()}, []]}
      })

    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | attachment: %DevIDE.Terminals.Attachment{
            kind: :shell,
            backend: DevIDE.Terminals.Session,
            pid: fake_session
          }
      }
    end)

    {owner_pid, fake_session}
  end

  defp start_shell_owner(workspace_id, info) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        DevIDE.Terminals.Supervisor,
        {DevIDE.Terminals.SessionOwner, {workspace_id, info}}
      )

    pid
  end

  # Seeds a stub :unavailable-snapshot attachment so a fresh raw `owner_attach`
  # on a shell owner returns {:ok, ...} (skipping the headless-impossible PTY
  # open) and replays from the OWNER's replay_buffer — the same path the former
  # execution owners exercised. A dead pid makes Attachment.snapshot/1 return
  # :unavailable (forcing the replay_buffer fallback), and the Session backend
  # clause makes Attachment.close/1 a no-op.
  defp seed_stub_attachment(owner_pid) do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 500

    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | attachment: %DevIDE.Terminals.Attachment{
            kind: :shell,
            backend: DevIDE.Terminals.Session,
            pid: dead
          }
      }
    end)

    owner_pid
  end

  defp register_subscriber(owner_pid, subscriber, mode) do
    :sys.replace_state(owner_pid, fn state ->
      state = %{state | subscribers: Map.put(state.subscribers, subscriber, mode)}

      if mode == :raw do
        %{state | raw_subscribers: MapSet.put(state.raw_subscribers, subscriber)}
      else
        state
      end
    end)

    owner_pid
  end

  # The owner's tmux resize runs as a single-flight async task; wait for the
  # owner to clear the slot so the next drift tick starts a fresh re-assert.
  defp await_resize_settled(owner_pid, attempts \\ 100)
  defp await_resize_settled(_owner_pid, 0), do: :ok

  defp await_resize_settled(owner_pid, attempts) do
    case :sys.get_state(owner_pid) do
      %{tmux_resize: nil} ->
        :ok

      _in_flight ->
        Process.sleep(10)
        await_resize_settled(owner_pid, attempts - 1)
    end
  end

  defp relay(owner, tag) do
    receive do
      {:terminal_payload, :data, payload} ->
        send(owner, {tag, payload})
        relay(owner, tag)

      _other ->
        relay(owner, tag)
    end
  end

  defp attachment_count_for(list, key) do
    Enum.find_value(list, fn
      {^key, count} -> count
      _ -> nil
    end) || 0
  end
end
