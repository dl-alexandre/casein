defmodule Casein.Terminals.SessionDirectoryEventsTest do
  @moduledoc """
  Event-source path for SessionDirectory — FakeEventSource driven, no real tmux.
  """

  use Casein.TestCase, async: false

  alias Casein.Terminals.SessionDirectory
  alias TmuxCtl.Test.FakeEventSource
  alias TmuxCtl.Test.FakeState

  setup do
    prev_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_windows = FakeState.get(:fake_tmux_windows)
    prev_panes = FakeState.get(:fake_tmux_panes)
    prev_poll = Application.get_env(:casein, :session_directory_poll_ms)
    prev_reconcile = Application.get_env(:casein, :session_directory_reconcile_ms)

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    {:ok, fake} = start_supervised(FakeEventSource)

    on_exit(fn ->
      restore(:tmux_adapter, prev_adapter)
      FakeState.restore(:fake_tmux_windows, prev_windows)
      FakeState.restore(:fake_tmux_panes, prev_panes)
      restore(:session_directory_poll_ms, prev_poll)
      restore(:session_directory_reconcile_ms, prev_reconcile)
    end)

    %{fake: fake}
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  test "event triggers recompute and sessions_updated broadcast", %{fake: fake} do
    ws = "sdevt-#{System.unique_integer([:positive])}"
    put_fake_session("casein_#{ws}_u-alice")

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: 200,
                 reconcile_ms: 60_000
               )
             )

    assert [%{sid: "u-alice"}] = SessionDirectory.tabs(ws, workspace_name: ws)
    flush_sessions_updated(ws)

    put_fake_session("casein_#{ws}_u-bob")

    FakeEventSource.emit(fake, %{
      type: :window_add,
      window_id: "@2",
      raw: "%window-add @2"
    })

    assert_receive {SessionDirectory, {:sessions_updated, ^ws, tabs}}, 1_000
    assert Enum.map(tabs, & &1.sid) |> Enum.sort() == ["u-alice", "u-bob"]
  end

  test "coalesces events within min_interval (old poll period) into one recompute", %{fake: fake} do
    ws = "sdevt-coal-#{System.unique_integer([:positive])}"
    put_fake_session("casein_#{ws}_u-alice")

    counter = :counters.new(1, [:atomics])
    install_counting_adapter(counter)

    min_interval = 200

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: min_interval,
                 reconcile_ms: 60_000
               )
             )

    pid = directory_pid!(ws)
    # Initial load + subscribe tabs path may recompute; wait for settle.
    init_calls = wait_counter_stable(pid, counter)
    assert init_calls >= 1

    # Burst of events well inside min_interval.
    for i <- 1..5 do
      put_fake_session("casein_#{ws}_u-extra#{i}")
      FakeEventSource.emit(fake, %{type: :sessions_changed, raw: "%sessions-changed"})
    end

    # One coalesced recompute (or at most one immediate + one deferred) must land.
    wait_until(fn -> :counters.get(counter, 1) > init_calls end)
    # Let any trailing deferred edge settle before reading the final delta.
    calls_after = wait_counter_stable(pid, counter)

    # At most one extra recompute (list_sessions call) beyond the settle baseline.
    # The <= 2 upper bound is the tooth: unthrottled bursts must not pass.
    assert calls_after - init_calls <= 2
    assert calls_after > init_calls
  end

  test "listener_down falls back to poll_ms cadence; event mode stretches to reconcile", %{
    fake: fake
  } do
    ws = "sdevt-fb-#{System.unique_integer([:positive])}"
    put_fake_session("casein_#{ws}_u-alice")

    counter = :counters.new(1, [:atomics])
    install_counting_adapter(counter)

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: 50,
                 reconcile_ms: 60_000
               )
             )

    pid = directory_pid!(ws)

    # Connected event mode: only reconcile (60s) would fire — count stays near init.
    mid = wait_counter_stable(pid, counter)

    FakeEventSource.set_connected(fake, false)
    flush_state(pid)

    # Fast poll fallback should fire several times.
    wait_until(fn -> :counters.get(counter, 1) > mid + 1 end)
    after_down = :counters.get(counter, 1)
    assert after_down > mid + 1

    put_fake_session("casein_#{ws}_u-bob")
    flush_sessions_updated(ws)

    FakeEventSource.set_connected(fake, true)

    assert_receive {SessionDirectory, {:sessions_updated, ^ws, tabs}}, 1_000
    assert Enum.map(tabs, & &1.sid) |> Enum.sort() == ["u-alice", "u-bob"]
  end

  test "duplicate listener_up in event mode does not trigger extra recomputes", %{fake: fake} do
    ws = "sdevt-dup-#{System.unique_integer([:positive])}"
    put_fake_session("casein_#{ws}_u-alice")

    counter = :counters.new(1, [:atomics])
    install_counting_adapter(counter)

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: 50,
                 reconcile_ms: 60_000
               )
             )

    pid = directory_pid!(ws)
    before = wait_counter_stable(pid, counter)

    for _ <- 1..5, do: send(pid, {TmuxCtl.Events, {:listener_up, "dup"}})
    flush_state(pid)

    assert :counters.get(counter, 1) == before
    assert Process.alive?(pid)
  end

  test "reconcile tick still recomputes with zero events", %{fake: fake} do
    ws = "sdevt-rec-#{System.unique_integer([:positive])}"
    put_fake_session("casein_#{ws}_u-alice")

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: 60_000,
                 reconcile_ms: 40
               )
             )

    assert [%{sid: "u-alice"}] = SessionDirectory.tabs(ws, workspace_name: ws)
    flush_sessions_updated(ws)

    # No FakeEventSource.emit — only the stretched reconcile timer.
    put_fake_session("casein_#{ws}_u-bob")

    assert_receive {SessionDirectory, {:sessions_updated, ^ws, tabs}}, 1_000
    assert Enum.map(tabs, & &1.sid) |> Enum.sort() == ["u-alice", "u-bob"]
  end

  test "event_source nil keeps pure 2s-style polling (existing path)", %{fake: _fake} do
    ws = "sdevt-nil-#{System.unique_integer([:positive])}"
    put_fake_session("casein_#{ws}_u-alice")

    counter = :counters.new(1, [:atomics])
    install_counting_adapter(counter)

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               workspace_name: ws,
               event_source: nil,
               poll_ms: 50,
               reconcile_ms: 60_000
             )

    # Pure polling at 50ms must keep firing.
    wait_until(fn -> :counters.get(counter, 1) >= 2 end)
    after_poll = :counters.get(counter, 1)
    assert after_poll >= 2

    put_fake_session("casein_#{ws}_u-bob")
    assert_receive {SessionDirectory, {:sessions_updated, ^ws, tabs}}, 1_000
    assert Enum.map(tabs, & &1.sid) |> Enum.sort() == ["u-alice", "u-bob"]
  end

  test "pane_mode_changed does not trigger an event recompute", %{fake: fake} do
    ws = "sdevt-pane-#{System.unique_integer([:positive])}"
    put_fake_session("casein_#{ws}_u-alice")

    counter = :counters.new(1, [:atomics])
    install_counting_adapter(counter)

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: 200,
                 reconcile_ms: 60_000
               )
             )

    pid = directory_pid!(ws)
    before = wait_counter_stable(pid, counter)

    put_fake_session("casein_#{ws}_u-bob")
    FakeEventSource.emit(fake, %{type: :pane_mode_changed, pane_id: "%1"})
    flush_state(pid)

    # No event-driven recompute; count must not jump for the ignored type.
    assert :counters.get(counter, 1) == before
    refute_receive {SessionDirectory, {:sessions_updated, ^ws, _}}, 100
  end

  test "second event inside min_interval is deferred, not immediate and not dropped", %{
    fake: fake
  } do
    ws = "sdevt-defer-#{System.unique_integer([:positive])}"
    put_fake_session("casein_#{ws}_u-alice")

    counter = :counters.new(1, [:atomics])
    install_counting_adapter(counter)

    min_interval = 400

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: min_interval,
                 reconcile_ms: 60_000
               )
             )

    pid = directory_pid!(ws)
    init_calls = wait_counter_stable(pid, counter)

    # The min-interval window opens at the initial load; wait it out so event
    # A is genuinely unthrottled.
    wait_until(fn ->
      %{last_recompute_ms: last} = :sys.get_state(pid)
      System.monotonic_time(:millisecond) - last >= min_interval
    end)

    # Event A recomputes immediately (nothing recent).
    put_fake_session("casein_#{ws}_u-bob")
    FakeEventSource.emit(fake, %{type: :sessions_changed, raw: "%sessions-changed"})
    flush_state(pid)
    wait_until(fn -> :counters.get(counter, 1) == init_calls + 1 end)
    after_a = :counters.get(counter, 1)
    assert after_a == init_calls + 1

    # Event B lands inside min_interval AFTER A's recompute completed, so the
    # single-flight guard cannot mask it: an unthrottled implementation would
    # recompute immediately here.
    put_fake_session("casein_#{ws}_u-carol")
    FakeEventSource.emit(fake, %{type: :sessions_changed, raw: "%sessions-changed"})
    flush_state(pid)
    # Hold the "no immediate recompute" tooth across a short window so an
    # async unthrottled recompute cannot race past a single counter sample.
    assert_counter_holds(counter, after_a, 100)

    # ...and it must be deferred to the window edge, never dropped.
    wait_until(fn -> :counters.get(counter, 1) == after_a + 1 end)

    assert Enum.map(SessionDirectory.tabs(ws, workspace_name: ws), & &1.sid) |> Enum.sort() ==
             ["u-alice", "u-bob", "u-carol"]
  end

  test "quiet flip broadcasts via reconcile in event mode with zero events", %{fake: fake} do
    ws = "sdevt-quiet-#{System.unique_integer([:positive])}"
    tmux_session = "casein_#{ws}_u-alice"
    now = DateTime.utc_now() |> DateTime.to_unix()

    put_agent_window = fn activity ->
      FakeState.update(:fake_tmux_windows, %{}, fn windows ->
        Map.put(windows, tmux_session, [
          %{
            id: "@1",
            index: 0,
            name: "agent",
            active: true,
            panes: 1,
            activity: activity,
            current_command: "claude"
          }
        ])
      end)
    end

    # Fresh activity: not quiet.
    put_agent_window.(now)

    # poll_ms is deliberately huge: only the reconcile tick may drive this.
    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: 60_000,
                 reconcile_ms: 250
               )
             )

    assert [%{metadata: %{windows: [%{quiet: false}]}}] =
             SessionDirectory.tabs(ws, workspace_name: ws)

    flush_sessions_updated(ws)

    # Agent goes silent long enough to flip quiet. NO event fires (silence has
    # no notification) — the reconcile backbone must still broadcast the flip.
    put_agent_window.(now - 120)

    assert_receive {SessionDirectory, {:sessions_updated, ^ws, tabs}}, 2_000
    assert [%{metadata: %{windows: [%{id: "@1", quiet: true}]}}] = tabs
  end

  test "volatile-only activity change + event recomputes without broadcasting", %{fake: fake} do
    ws = "sdevt-vol-#{System.unique_integer([:positive])}"
    tmux_session = "casein_#{ws}_u-alice"

    put_shell_window = fn activity ->
      FakeState.update(:fake_tmux_windows, %{}, fn windows ->
        Map.put(windows, tmux_session, [
          %{
            id: "@1",
            index: 0,
            name: "shell",
            active: true,
            panes: 1,
            activity: activity,
            current_command: "bash"
          }
        ])
      end)
    end

    put_shell_window.(1_000)

    counter = :counters.new(1, [:atomics])
    install_counting_adapter(counter)

    assert :ok =
             SessionDirectory.subscribe(
               ws,
               directory_opts(fake,
                 workspace_name: ws,
                 poll_ms: 100,
                 reconcile_ms: 60_000
               )
             )

    pid = directory_pid!(ws)
    before = wait_counter_stable(pid, counter)
    flush_sessions_updated(ws)

    # Activity timestamp moves (volatile, outside the stable hash); the shell
    # window can never flip quiet, so tabs are hash-identical.
    put_shell_window.(2_000)
    FakeEventSource.emit(fake, %{type: :window_renamed, window_id: "@1", raw: "%window-renamed"})
    flush_state(pid)
    wait_until(fn -> :counters.get(counter, 1) > before end)

    # The event DID recompute...
    assert :counters.get(counter, 1) > before
    # ...but a volatile-only change must not re-broadcast.
    refute_receive {SessionDirectory, {:sessions_updated, ^ws, _}}, 100
  end

  # -- helpers --------------------------------------------------------------

  defp directory_opts(fake, overrides) do
    [
      event_source: {FakeEventSource, fake},
      poll_ms: 200,
      reconcile_ms: 60_000
    ]
    |> Keyword.merge(overrides)
  end

  defp directory_pid!(workspace_id) do
    assert {:ok, pid} =
             SessionDirectory.ensure_started(workspace_id, workspace_name: workspace_id)

    pid
  end

  defp put_fake_session(tmux_session, current_path \\ nil) do
    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, tmux_session, [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ])
    end)

    if is_binary(current_path) do
      FakeState.update(:fake_tmux_panes, %{}, fn panes ->
        Map.put(panes, tmux_session, [
          %{
            id: "%1",
            window_id: "@1",
            index: 0,
            active: true,
            left: 0,
            top: 0,
            width: 120,
            height: 40,
            current_command: "bash",
            current_path: current_path
          }
        ])
      end)
    end
  end

  defp flush_sessions_updated(ws) do
    receive do
      {SessionDirectory, {:sessions_updated, ^ws, _}} -> flush_sessions_updated(ws)
    after
      0 -> :ok
    end
  end

  defp install_counting_adapter(counter) do
    :persistent_term.put({__MODULE__, :recompute_counter}, counter)
    Application.put_env(:casein, :tmux_adapter, __MODULE__.CountingAdapter)
  end

  # Drain SessionDirectory's mailbox through the event (and any synchronous
  # recompute it started). Prefer this over wall-clock sleeps before counter
  # baselines / refute_receive after a known emit.
  defp flush_state(pid) do
    _ = :sys.get_state(pid)
    :ok
  end

  # Poll `fun` until truthy or `timeout` ms, then flunk. Use for "a recompute
  # WILL happen" and timer-driven cadence assertions.
  defp wait_until(fun, timeout \\ 2_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout)
  end

  defp do_wait_until(fun, deadline, timeout) do
    case fun.() do
      result when result not in [false, nil] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("wait_until timed out after #{timeout}ms")
        else
          receive do
          after
            15 -> :ok
          end

          do_wait_until(fun, deadline, timeout)
        end
    end
  end

  # Settle init_calls/before by requiring two consecutive counter reads (with
  # a mailbox flush between) to match — no fixed wall-clock settle window.
  defp wait_counter_stable(pid, counter, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    flush_state(pid)
    prev = :counters.get(counter, 1)
    do_wait_counter_stable(pid, counter, prev, deadline)
  end

  defp do_wait_counter_stable(pid, counter, prev, deadline) do
    receive do
    after
      15 -> :ok
    end

    flush_state(pid)
    next = :counters.get(counter, 1)

    cond do
      next == prev ->
        next

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_counter_stable timed out (last=#{next}, prev=#{prev})")

      true ->
        do_wait_counter_stable(pid, counter, next, deadline)
    end
  end

  # Assert the counter stays at `expected` for the full `hold_ms` window.
  # Used for "must NOT recompute immediately" teeth so async recomputes cannot
  # race a single post-flush sample.
  defp assert_counter_holds(counter, expected, hold_ms) do
    deadline = System.monotonic_time(:millisecond) + hold_ms
    do_assert_counter_holds(counter, expected, deadline)
  end

  defp do_assert_counter_holds(counter, expected, deadline) do
    actual = :counters.get(counter, 1)

    if actual != expected do
      flunk("expected counter to hold at #{expected} (got #{actual})")
    end

    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      receive do
      after
        10 -> :ok
      end

      do_assert_counter_holds(counter, expected, deadline)
    end
  end
end

defmodule Casein.Terminals.SessionDirectoryEventsTest.CountingAdapter do
  @moduledoc false

  # Counts list_sessions/0 — every SessionDirectory recompute calls it.
  def list_sessions do
    case :persistent_term.get(
           {Casein.Terminals.SessionDirectoryEventsTest, :recompute_counter},
           nil
         ) do
      nil -> :ok
      counter -> :counters.add(counter, 1, 1)
    end

    Casein.Test.FakeTmuxAdapter.list_sessions()
  end

  def directory_inventory, do: Casein.Test.FakeTmuxAdapter.directory_inventory()
  def list_session_windows(session), do: Casein.Test.FakeTmuxAdapter.list_session_windows(session)
  def list_session_panes(session), do: Casein.Test.FakeTmuxAdapter.list_session_panes(session)

  # Mobile terminal lease cleanup calls this unguarded (TerminalSessions).
  defdelegate session_exists?(session), to: Casein.Test.FakeTmuxAdapter
end
