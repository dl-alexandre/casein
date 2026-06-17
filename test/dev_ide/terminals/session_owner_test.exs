defmodule DevIDE.Terminals.SessionOwnerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals
  alias DevIDE.Terminals.Telemetry
  alias DevIDE.Terminals.Session.Info

  test "shell owners remain alive after explicit detach (no auto-stop)" do
    info = Terminals.new_shell("ws-shell-stop", "shell-keep-alive")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-shell-stop", info,
        mode: :governed,
        session_id: "shell-keep-alive"
      )

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

  test "execution owners stop when no subscribers remain" do
    info =
      Terminals.new_execution("exec-stop", "tmux-exec-stop",
        workspace_id: "ws-exec-stop",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-stop", info, mode: :raw, session_id: "exec-stop")

    monitor = Process.monitor(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, self())

    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "execution owners only stop after all subscribers detach" do
    info =
      Terminals.new_execution("exec-shared-stop", "tmux-exec-shared-stop",
        workspace_id: "ws-exec-shared-stop",
        loc: :remote
      )

    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-shared-stop", info,
        mode: :governed,
        session_id: "exec-shared-stop"
      )

    monitor = Process.monitor(owner_pid)

    secondary =
      spawn(fn ->
        {:ok, _sec_owner_pid, _} =
          Terminals.owner_attach("ws-exec-shared-stop", info,
            mode: :governed,
            session_id: "exec-shared-stop"
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

  test "detaching a non-subscriber on execution owner is a no-op" do
    info =
      Terminals.new_execution("exec-idempotent", "tmux-exec-idempotent",
        workspace_id: "ws-exec-idempotent",
        loc: :remote
      )

    bogus =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-idempotent", info,
        mode: :governed,
        session_id: "exec-idempotent"
      )

    monitor = Process.monitor(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, bogus)
    assert Process.alive?(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
    Process.exit(bogus, :kill)
  end

  test "subscriber exits are cleaned up via monitor and do not stop owner while others remain" do
    info =
      Terminals.new_execution("exec-exit-cleanup", "tmux-exec-exit-cleanup",
        workspace_id: "ws-exec-exit-cleanup",
        loc: :remote
      )

    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-exit-cleanup", info,
        mode: :raw,
        session_id: "exec-exit-cleanup"
      )

    monitor = Process.monitor(owner_pid)

    subscriber =
      spawn(fn ->
        {:ok, ^owner_pid, _} =
          Terminals.owner_attach("ws-exec-exit-cleanup", info,
            mode: :raw,
            session_id: "exec-exit-cleanup"
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
      Terminals.owner_attach("ws-agent-stop", info, mode: :governed, session_id: "agent-stop")

    monitor = Process.monitor(owner_pid)

    assert :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "raw re-attachments receive bounded terminal replay from owner" do
    info =
      Terminals.new_execution("exec-replay", "tmux-exec-replay",
        workspace_id: "ws-exec-replay",
        loc: :remote
      )

    owner_key = "owner-replay-test"
    parent = self()

    first =
      spawn(fn ->
        {:ok, owner_pid, _} =
          Terminals.owner_attach("ws-exec-replay", info, mode: :raw, session_id: owner_key)

        send(parent, {:attached, owner_pid})
        relay(parent, :first)
      end)

    assert_receive {:attached, owner_pid}, 1_000

    send(owner_pid, {:term_data, :ignore, "before-replay-1", :replay})
    send(owner_pid, {:term_data, :ignore, "before-replay-2"})

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-exec-replay", info, mode: :raw, session_id: owner_key)

        relay(parent, :second)
      end)

    monitor = Process.monitor(owner_pid)

    assert_receive {:second, %{data: data, replay: true}}, 1_500
    assert data =~ "before-replay-1"
    assert data =~ "before-replay-2"

    Process.exit(first, :kill)
    Process.exit(second, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "raw replay payload strips cursor report escape sequence" do
    info =
      Terminals.new_execution("exec-control", "tmux-exec-control",
        workspace_id: "ws-exec-control",
        loc: :remote
      )

    owner_key = "owner-control"
    parent = self()

    first =
      spawn(fn ->
        {:ok, owner_pid, _} =
          Terminals.owner_attach("ws-exec-control", info, mode: :raw, session_id: owner_key)

        send(parent, {:attached, owner_pid})
        relay(parent, :control_first)
      end)

    assert_receive {:attached, owner_pid}, 1_000

    send(owner_pid, {:term_data, :ignore, "\e[12;34Rhello", :replay})

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-exec-control", info, mode: :raw, session_id: owner_key)

        relay(parent, :control_second)
      end)

    monitor = Process.monitor(owner_pid)

    assert_receive {:control_second, payload}, 1_500
    assert payload.data == "hello"
    assert payload.replay == true
    refute String.contains?(payload.data, "\e[")

    Process.exit(first, :kill)
    Process.exit(second, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "raw replay payload strips terminal capability handshakes" do
    info =
      Terminals.new_execution("exec-xtversion", "tmux-exec-xtversion",
        workspace_id: "ws-exec-xtversion",
        loc: :remote
      )

    owner_key = "owner-xtversion"
    parent = self()

    first =
      spawn(fn ->
        {:ok, owner_pid, _} =
          Terminals.owner_attach("ws-exec-xtversion", info, mode: :raw, session_id: owner_key)

        send(parent, {:attached, owner_pid})
        relay(parent, :xtversion_first)
      end)

    assert_receive {:attached, owner_pid}, 1_000

    send(
      owner_pid,
      {:term_data, :ignore, "before\e[>q\eP>|libghostty\e\\\e[c\e[?62;22c\e[>1;0;0cafter",
       :replay}
    )

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-exec-xtversion", info, mode: :raw, session_id: owner_key)

        relay(parent, :xtversion_second)
      end)

    monitor = Process.monitor(owner_pid)

    assert_receive {:xtversion_second, payload}, 1_500
    assert payload.data == "beforeafter"
    assert payload.replay == true
    refute String.contains?(payload.data, "\e[>q")
    refute String.contains?(payload.data, "libghostty")
    refute String.contains?(payload.data, "62;22c")
    refute String.contains?(payload.data, "1;0;0c")

    Process.exit(first, :kill)
    Process.exit(second, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "governed attach does not accumulate replay frame when no raw viewer was active" do
    info =
      Terminals.new_execution("exec-no-raw", "tmux-no-raw",
        workspace_id: "ws-no-raw",
        loc: :remote
      )

    owner_key = "owner-no-raw"

    {:ok, owner_pid, _} =
      Terminals.owner_attach(
        "ws-no-raw",
        info,
        mode: :governed,
        session_id: owner_key
      )

    send(owner_pid, {:term_data, :ignore, "pre-reconnect", :replay})
    assert_receive {:terminal_payload, :data, %{data: "pre-reconnect"}}, 1_000

    assert {:ok, ^owner_pid, _} =
             Terminals.owner_attach(
               "ws-no-raw",
               info,
               mode: :governed,
               session_id: owner_key
             )

    refute_receive {:terminal_payload, :data, %{replay: true}}, 250

    send(owner_pid, {:term_data, :ignore, "after-reconnect", :replay})
    assert_receive {:terminal_payload, :data, %{data: "after-reconnect"}}, 1_000
    :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "raw owner accepts Ghostty PTY write calls without crashing" do
    info =
      Terminals.new_execution("exec-ghostty-write", "tmux-ghostty-write",
        workspace_id: "ws-ghostty-write",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-ghostty-write", info,
        mode: :raw,
        session_id: "ghostty-write"
      )

    monitor = Process.monitor(owner_pid)

    assert :ok = GenServer.call(owner_pid, {:write, "o"})
    assert :ok = GenServer.call(owner_pid, {:write, "\e[I"})
    refute_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason}, 250

    :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "raw replay buffer only includes output seen while a raw subscriber was attached" do
    info =
      Terminals.new_execution("exec-replay-window", "tmux-exec-replay-window",
        workspace_id: "ws-exec-replay-window",
        loc: :remote
      )

    owner_key = "exec-replay-window"
    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach(
        "ws-exec-replay-window",
        info,
        mode: :raw,
        session_id: owner_key
      )

    monitor = Process.monitor(owner_pid)

    secondary =
      spawn(fn ->
        {:ok, ^owner_pid, _} =
          Terminals.owner_attach(
            "ws-exec-replay-window",
            info,
            mode: :governed,
            session_id: owner_key
          )

        send(parent, :secondary_attached)

        receive do
          :release ->
            :ok = Terminals.owner_detach(owner_pid, self())
            send(parent, :secondary_released)
        end
      end)

    assert_receive :secondary_attached, 1_000

    send(owner_pid, {:term_data, :ignore, "should-replay\n"})
    :ok = Terminals.owner_detach(owner_pid, self())

    send(owner_pid, {:term_data, :ignore, "should-not-replay\n"})

    assert {:ok, ^owner_pid, _} =
             Terminals.owner_attach("ws-exec-replay-window", info,
               mode: :raw,
               session_id: owner_key
             )

    assert_receive {:terminal_payload, :data, %{replay: true, data: data}}, 1_000
    assert data =~ "should-replay"
    refute data =~ "should-not-replay"

    send(secondary, :release)
    assert_receive :secondary_released, 1_000
    :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "governed attach preserves cursor report data in terminal payload" do
    info =
      Terminals.new_execution("exec-governed-cursor", "tmux-exec-governed-cursor",
        workspace_id: "ws-exec-governed-cursor",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-governed-cursor", info,
        mode: :governed,
        session_id: "exec-governed-cursor"
      )

    send(owner_pid, {:term_data, :ignore, "\e[12;34Rgoverned", :replay})

    assert_receive {:terminal_payload, :data, %{data: "\e[12;34Rgoverned"}}, 1_000

    :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "governed-only output does not accumulate replay buffer" do
    info =
      Terminals.new_execution("exec-governed-replay-gating", "tmux-exec-governed-replay-gating",
        workspace_id: "ws-exec-governed-replay-gating",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach(
        "ws-exec-governed-replay-gating",
        info,
        mode: :governed,
        session_id: "replay-gating"
      )

    send(owner_pid, {:term_data, :ignore, "governed-buf-1", :replay})
    send(owner_pid, {:term_data, :ignore, "governed-buf-2"})

    assert_receive {:terminal_payload, :data, %{data: "governed-buf-1"}}, 1_000
    assert_receive {:terminal_payload, :data, %{data: "governed-buf-2"}}, 1_000
    refute_receive {:terminal_payload, :data, %{replay: true}}, 150

    assert byte_size(:sys.get_state(owner_pid).replay_buffer) == 0

    :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "raw attach enables replay buffering for output replay" do
    info =
      Terminals.new_execution("exec-raw-buffer-turn-on", "tmux-exec-raw-buffer-turn-on",
        workspace_id: "ws-exec-raw-buffer-turn-on",
        loc: :remote
      )

    owner_key = "raw-buffer-turn-on"
    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-raw-buffer-turn-on", info,
        mode: :raw,
        session_id: owner_key
      )

    send(owner_pid, {:term_data, :ignore, "raw-snapshot", :replay})

    second =
      spawn(fn ->
        {:ok, ^owner_pid, _} =
          Terminals.owner_attach(
            "ws-exec-raw-buffer-turn-on",
            info,
            mode: :raw,
            session_id: owner_key
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
    :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "non-binary term_data is ignored without stopping execution owner" do
    info =
      Terminals.new_execution("exec-bad-data", "tmux-exec-bad-data",
        workspace_id: "ws-exec-bad-data",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-bad-data", info, mode: :raw, session_id: "bad-data")

    monitor = Process.monitor(owner_pid)

    send(owner_pid, {:term_data, :ignore, :not_a_binary})
    send(owner_pid, {:term_data, :ignore, "good-data", :replay})

    assert_receive {:terminal_payload, :data, %{data: "good-data"}}, 1_000
    refute_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 400

    :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 2_000
  end

  test "single arity term_data is processed exactly once" do
    info =
      Terminals.new_execution("exec-termdata-raw", "tmux-exec-termdata",
        workspace_id: "ws-exec-termdata",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-termdata", info, mode: :raw, session_id: "termdata-single")

    send(owner_pid, {:term_data, "abc"})

    assert_receive {:terminal_payload, :data, %{data: "abc"}}, 1_000
    refute_receive {:terminal_payload, :data, %{data: "abc"}}, 150

    :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "unexpected term_data shapes are ignored safely" do
    info =
      Terminals.new_execution("exec-termdata-unexpected", "tmux-exec-unexpected",
        workspace_id: "ws-exec-termdata-unexpected",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-termdata-unexpected", info,
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
    info =
      Terminals.new_execution("exec-truncate", "tmux-exec-truncate",
        workspace_id: "ws-exec-truncate",
        loc: :remote
      )

    owner_key = "owner-replay-truncate"
    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-truncate", info, mode: :raw, session_id: owner_key)

    send(owner_pid, {:term_data, :ignore, String.duplicate("A", 20_000), :replay})
    send(owner_pid, {:term_data, :ignore, String.duplicate("B", 20_000), :replay})

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-exec-truncate", info, mode: :raw, session_id: owner_key)

        relay(parent, :truncate)
      end)

    monitor = Process.monitor(owner_pid)

    assert_receive {:truncate, %{data: replay, replay: true}}, 1_000
    assert byte_size(replay) <= 32 * 1024

    Process.exit(second, :kill)
    assert :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 1_000
  end

  test "replay truncation honors runtime replay buffer limit configuration" do
    previous_limit = Application.get_env(:dev_ide, :terminal_replay_buffer_bytes)
    Application.put_env(:dev_ide, :terminal_replay_buffer_bytes, 6)

    try do
      info =
        Terminals.new_execution("exec-config-truncate", "tmux-exec-config-truncate",
          workspace_id: "ws-exec-config-truncate",
          loc: :remote
        )

      owner_key = "owner-config-truncate"
      parent = self()

      {:ok, owner_pid, _} =
        Terminals.owner_attach("ws-exec-config-truncate", info,
          mode: :raw,
          session_id: owner_key
        )

      send(owner_pid, {:term_data, :ignore, "AAAAAA", :replay})
      send(owner_pid, {:term_data, :ignore, "BBBBBB", :replay})

      second =
        spawn(fn ->
          {:ok, _, _} =
            Terminals.owner_attach("ws-exec-config-truncate", info,
              mode: :raw,
              session_id: owner_key
            )

          relay(parent, :config_truncate)
        end)

      monitor = Process.monitor(owner_pid)

      assert_receive {:config_truncate, %{data: replay, replay: true}}, 1_000
      assert replay == "BBBBBB"

      Process.exit(second, :kill)
      assert :ok = Terminals.owner_detach(owner_pid, self())
      assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 1_000
    after
      if previous_limit == nil do
        Application.delete_env(:dev_ide, :terminal_replay_buffer_bytes)
      else
        Application.put_env(:dev_ide, :terminal_replay_buffer_bytes, previous_limit)
      end
    end
  end

  test "raw attach does not replay output that was produced before raw subscriber existed" do
    info =
      Terminals.new_execution("exec-late-replay", "tmux-late-replay",
        workspace_id: "ws-late-replay",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-late-replay", info, mode: :governed, session_id: "late-replay")

    send(owner_pid, {:term_data, :ignore, "no-replay-yet", :replay})
    assert_receive {:terminal_payload, :data, %{data: "no-replay-yet"}}, 1_000

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-late-replay", info, mode: :raw, session_id: "late-replay")

    refute_receive {:terminal_payload, :data, %{data: _}}, 150

    send(owner_pid, {:term_data, :ignore, "live-after-raw"})
    assert_receive {:terminal_payload, :data, %{data: "live-after-raw"}}, 1_000

    :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "raw attachment opens underlying attachment once and closes it once" do
    unique = System.unique_integer([:positive])

    info =
      Terminals.new_execution("exec-open-close-#{unique}", "tmux-open-close-#{unique}",
        workspace_id: "ws-open-close-#{unique}",
        loc: :remote
      )

    baseline = Telemetry.count_open_attachments()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-open-close-#{unique}", info,
        mode: :raw,
        session_id: "open-close"
      )

    assert Telemetry.count_open_attachments() == baseline + 1

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-open-close-#{unique}", info,
        mode: :raw,
        session_id: "open-close"
      )

    assert Telemetry.count_open_attachments() == baseline + 1

    assert :ok = Terminals.owner_detach(owner_pid, self())
    monitor = Process.monitor(owner_pid)
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
    assert Telemetry.count_open_attachments() == baseline
  end

  test "duplicate attach by same subscriber is idempotent and does not duplicate attachment opens" do
    unique = System.unique_integer([:positive])

    info =
      Terminals.new_execution("exec-dupe-#{unique}", "tmux-dupe-#{unique}",
        workspace_id: "ws-dupe-#{unique}",
        loc: :remote
      )

    expected_key = {:terminal_owner, :execution, info.execution_id}
    baseline = Telemetry.count_open_attachments()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-dupe-#{unique}", info,
        mode: :raw,
        session_id: "exec-dupe"
      )

    assert attachment_count_for(Telemetry.subscribers_per_owner(), expected_key) == 1
    assert Telemetry.count_open_attachments() == baseline + 1

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-dupe-#{unique}", info,
        mode: :raw,
        session_id: "exec-dupe"
      )

    assert attachment_count_for(Telemetry.subscribers_per_owner(), expected_key) == 1
    assert Telemetry.count_open_attachments() == baseline + 1

    monitor = Process.monitor(owner_pid)
    assert :ok = Terminals.owner_detach(owner_pid, self())
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
    assert Telemetry.count_open_attachments() == baseline
  end

  test "mode transition on same subscriber keeps a single attachment and updates raw fanout state" do
    unique = System.unique_integer([:positive])
    owner_key = "exec-mode-transition-#{unique}"

    info =
      Terminals.new_execution(owner_key, "tmux-#{owner_key}",
        workspace_id: "ws-#{owner_key}",
        loc: :remote
      )

    baseline = Telemetry.count_open_attachments()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-#{owner_key}", info, mode: :raw, session_id: owner_key)

    assert Telemetry.count_open_attachments() == baseline + 1
    assert Terminals.owner_subscriber_count(owner_pid) == 1

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-#{owner_key}", info, mode: :governed, session_id: owner_key)

    assert Telemetry.count_open_attachments() == baseline + 1
    assert Terminals.owner_subscriber_count(owner_pid) == 1

    send(owner_pid, {:term_data, :ignore, "governed-only-frame"})
    assert_receive {:terminal_payload, :data, %{data: "governed-only-frame"}}, 1_000
    refute_receive {:terminal_payload, :data, %{data: "governed-only-frame", replay: true}}, 150

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-#{owner_key}", info, mode: :raw, session_id: owner_key)

    assert Telemetry.count_open_attachments() == baseline + 1
    assert Terminals.owner_subscriber_count(owner_pid) == 1

    assert :ok = Terminals.owner_detach(owner_pid, self())
    monitor = Process.monitor(owner_pid)
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
    assert Telemetry.count_open_attachments() == baseline
  end

  test "shell output is only sent to raw subscribers" do
    unique = "shell-only-raw-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-shell-output", "sid-#{unique}")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-shell-output", info, mode: :governed, session_id: unique)

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

  test "shell mode transition from raw to governed disables raw fanout for that subscriber" do
    unique = "shell-mode-switch-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-shell-switch", "sid-#{unique}")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-shell-switch", info, mode: :governed, session_id: unique)

    test_pid = self()

    :sys.replace_state(owner_pid, fn state ->
      %{
        state
        | subscribers: Map.put(state.subscribers, test_pid, :raw),
          raw_subscribers: MapSet.put(state.raw_subscribers, test_pid)
      }
    end)

    send(owner_pid, {:term_data, :ignore, "before-switch"})
    assert_receive {:terminal_payload, :data, %{data: "before-switch"}}, 500

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-shell-switch", info, mode: :governed, session_id: unique)

    send(owner_pid, {:term_data, :ignore, "after-switch"})

    refute_receive {:terminal_payload, :data, %{data: "after-switch"}}, 250

    if Process.alive?(owner_pid) do
      GenServer.stop(owner_pid, :normal)
    end
  end

  test "governed re-attachments do not receive replay payloads" do
    info =
      Terminals.new_execution("exec-governed-replay", "tmux-exec-governed-replay",
        workspace_id: "ws-exec-governed-replay",
        loc: :remote
      )

    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-governed-replay", info,
        mode: :governed,
        session_id: "exec-governed-replay"
      )

    send(owner_pid, {:term_data, :ignore, "before-reattach-governed"})

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-exec-governed-replay", info,
            mode: :governed,
            session_id: "exec-governed-replay"
          )

        relay(parent, :governed_second)
      end)

    refute_receive {:governed_second, _}, 200

    send(owner_pid, {:term_data, :ignore, "after-reattach-governed"})
    assert_receive {:governed_second, payload_after}, 1_000
    assert payload_after.data == "after-reattach-governed"
    assert payload_after[:replay] != true

    Process.exit(second, :kill)

    assert :ok = Terminals.owner_detach(owner_pid, self())
  end

  test "execution owner sends terminal data to governed subscribers" do
    info =
      Terminals.new_execution("exec-no-raw", "tmux-exec-no-raw",
        workspace_id: "ws-no-raw",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-no-raw", info, mode: :governed, session_id: "exec-no-raw")

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
    info =
      Terminals.new_execution("exec-marker", "tmux-marker",
        workspace_id: "ws-marker",
        loc: :remote
      )

    owner_key = "owner-marker"
    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-marker", info, mode: :raw, session_id: owner_key)

    send(owner_pid, {:term_data, :ignore, "marker-data", :replay})

    second =
      spawn(fn ->
        {:ok, _, _} = Terminals.owner_attach("ws-marker", info, mode: :raw, session_id: owner_key)
        relay(parent, :marker)
      end)

    assert_receive {:marker, payload}, 1_000
    assert payload.replay == true
    assert payload.replay_frame == true
    assert payload.state_marker.kind == "replay"
    assert is_integer(payload.state_marker.ts)

    Process.exit(second, :kill)
    assert :ok = Terminals.owner_detach(owner_pid, self())
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
    info =
      Terminals.new_execution("exec-exit", "tmux-exec-exit",
        workspace_id: "ws-exec-exit",
        loc: :remote
      )

    parent = self()

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-exec-exit", info, mode: :governed, session_id: "exec-exit")

    monitor = Process.monitor(owner_pid)

    second =
      spawn(fn ->
        {:ok, _, _} =
          Terminals.owner_attach("ws-exec-exit", info, mode: :raw, session_id: "exec-exit")

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
    info =
      Terminals.new_execution("exec-term-exit-ref", "tmux-exec-term-exit-ref",
        workspace_id: "ws-term-exit-ref",
        loc: :remote
      )

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-term-exit-ref", info, mode: :raw, session_id: "term-exit-ref")

    monitor = Process.monitor(owner_pid)

    send(owner_pid, {:term_exit, make_ref(), :signal})
    assert_receive {:terminal_payload, :exit, :signal}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :normal}, 1_000
  end

  test "subscriber_count/1 and Terminals.owner_subscriber_count/1 return correct live count" do
    unique = "subcount-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-subcount", "sid-#{unique}")

    {:ok, owner_pid, _payload} =
      Terminals.owner_attach("ws-subcount", info, mode: :governed, session_id: unique)

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

    {:ok, owner_pid, _payload} =
      Terminals.owner_attach("ws-sync-resize", info, mode: :governed, session_id: unique)

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

  test "viewer-tagged resizes clamp the shared PTY to the smallest viewport" do
    unique = "clamp-resize-#{System.unique_integer([:positive])}"
    info = Terminals.new_shell("ws-clamp", "sid-#{unique}")

    # Governed attach makes the test process a real (monitored) subscriber, and
    # binds no workspace_key so the owner skips the best-effort tmux subprocess.
    {:ok, owner_pid, _payload} =
      Terminals.owner_attach("ws-clamp", info, mode: :governed, session_id: unique)

    fake_session =
      start_supervised!(%{
        id: {DevIDE.Test.FakeTerminalSession, unique},
        start:
          {GenServer, :start_link,
           [DevIDE.Test.FakeTerminalSession, {"ws-clamp", "sid-#{unique}", self()}, []]}
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

    # Wide viewer reports first, then a narrow viewer joins. The shared PTY must
    # follow the SMALLEST attached viewport, not the last writer.
    GenServer.cast(owner_pid, {:resize, big_viewer, 200, 60})
    assert_receive {:fake_session_resize, ^fake_session, 200, 60}

    GenServer.cast(owner_pid, {:resize, self(), 80, 24})
    assert_receive {:fake_session_resize, ^fake_session, 80, 24}

    # A no-op (same clamp) must not re-resize the attachment.
    GenServer.cast(owner_pid, {:resize, big_viewer, 200, 60})
    refute_receive {:fake_session_resize, ^fake_session, _, _}, 100

    # The narrow viewer (this process) detaches → clamp grows back to the wide one.
    :ok = GenServer.call(owner_pid, {:detach, self()})
    assert_receive {:fake_session_resize, ^fake_session, 200, 60}

    Process.exit(big_viewer, :kill)
  end

  test "later attach without context opts does not clobber workspace_key/loc binding" do
    info = Terminals.new_shell("ws-bind-keep", "shell-bind-keep")

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-bind-keep", info,
        mode: :governed,
        session_id: "shell-bind-keep",
        workspace_key: "ws-bind-keep",
        loc: {:cwd, "/tmp/ws-bind-keep"},
        host_id: "local"
      )

    state = :sys.get_state(owner_pid)
    assert state.workspace_key == "ws-bind-keep"
    assert state.loc == {:cwd, "/tmp/ws-bind-keep"}
    assert state.host_id == "local"

    # Re-attach (same subscriber) without any context opts — historical bug
    # clobbered the binding with nil, breaking subsequent raw attachment opens.
    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-bind-keep", info,
        mode: :governed,
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

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-bind-conflict", info,
        mode: :governed,
        session_id: "shell-bind-conflict",
        workspace_key: "ws-bind-conflict",
        loc: {:cwd, "/tmp/original"}
      )

    {:ok, ^owner_pid, _} =
      Terminals.owner_attach("ws-bind-conflict", info,
        mode: :governed,
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

    {:ok, owner_pid, _} =
      Terminals.owner_attach("ws-snap", info, mode: :governed, session_id: sid)

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
