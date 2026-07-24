defmodule DevIDE.Signals.TmuxEventsFlapWatchTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Audit.MemoryAdapter
  alias DevIDE.Signals.TmuxEventsFlapWatch

  @ops_ws "_ops"

  setup do
    prev_adapter = Application.get_env(:dev_ide, :audit_adapter)
    prev_flag = Application.get_env(:dev_ide, :tmux_events)
    Application.put_env(:dev_ide, :audit_adapter, MemoryAdapter)
    Application.put_env(:dev_ide, :tmux_events, true)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      restore(:audit_adapter, prev_adapter)
      restore(:tmux_events, prev_flag)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  defp start_watch(opts) do
    name = :"tmux_events_flap_#{System.unique_integer([:positive])}"

    start_supervised!(
      {TmuxEventsFlapWatch,
       Keyword.merge(
         [
           name: name,
           attach?: false,
           threshold: 3,
           window_ms: 60_000,
           sustained_ms: 50
         ],
         opts
       )}
    )
  end

  defp feed(pid, event) do
    feed(pid, event, %{label: "devide_test"})
  end

  defp feed(pid, event, meta) do
    TmuxEventsFlapWatch.notify(pid, event, meta)
    _ = :sys.get_state(pid)
  end

  defp audits(action) do
    @ops_ws
    |> Audit.recent_for(50)
    |> Enum.filter(&(&1.action == action))
  end

  # --- pure reduce ----------------------------------------------------------

  test "reduce: N downs within the window raise once" do
    base = %{
      threshold: 3,
      window_ms: 60_000,
      sustained_ms: 1_000,
      flap_times: [],
      raised?: false,
      connected_since: nil,
      sustained_timer: nil,
      label: "lab"
    }

    t0 = 1_000_000
    {s1, :noop} = TmuxEventsFlapWatch.reduce(base, :down, t0)
    {s2, :noop} = TmuxEventsFlapWatch.reduce(s1, :down, t0 + 10)
    {s3, :raise} = TmuxEventsFlapWatch.reduce(s2, :down, t0 + 20)
    assert length(s3.flap_times) == 3
  end

  test "reduce: downs outside the window do not raise" do
    base = %{
      threshold: 3,
      window_ms: 100,
      sustained_ms: 1_000,
      flap_times: [],
      raised?: false,
      connected_since: nil,
      sustained_timer: nil,
      label: "lab"
    }

    {s1, :noop} = TmuxEventsFlapWatch.reduce(base, :down, 1_000)
    {s2, :noop} = TmuxEventsFlapWatch.reduce(s1, :down, 1_010)
    # Outside window — only the newest flap remains.
    {s3, :noop} = TmuxEventsFlapWatch.reduce(s2, :down, 1_000 + 200)
    assert length(s3.flap_times) == 1
  end

  test "reduce: reconnect_attempt is not a flap" do
    base = %{
      threshold: 1,
      window_ms: 60_000,
      sustained_ms: 1_000,
      flap_times: [],
      raised?: false,
      connected_since: nil,
      sustained_timer: nil,
      label: "lab"
    }

    assert {^base, :noop} = TmuxEventsFlapWatch.reduce(base, :reconnect_attempt, 1)
  end

  # --- GenServer (audit surface, like DegradationWatch tests) ---------------

  test "N flaps within the window emit degraded audit once" do
    pid = start_watch(threshold: 3, window_ms: 60_000)

    for _ <- 1..2, do: feed(pid, :down)
    assert audits(TmuxEventsFlapWatch.degraded_action()) == []

    feed(pid, :down)
    assert [event] = audits(TmuxEventsFlapWatch.degraded_action())
    assert event.metadata["flaps"] >= 3
    assert event.metadata["threshold"] == 3

    # One episode: further flaps do not re-raise until cleared.
    feed(pid, :down)
    assert length(audits(TmuxEventsFlapWatch.degraded_action())) == 1
  end

  test "sustained connection clears a raised episode" do
    pid = start_watch(threshold: 2, window_ms: 60_000, sustained_ms: 30)

    feed(pid, :down)
    feed(pid, :down)
    assert [_] = audits(TmuxEventsFlapWatch.degraded_action())

    feed(pid, :up)

    assert_receive_audit(TmuxEventsFlapWatch.recovered_action(), 500)
    assert [_] = audits(TmuxEventsFlapWatch.recovered_action())
  end

  test "listener down past down_ms raises even without flapping" do
    pid = start_watch(threshold: 10, window_ms: 60_000, down_ms: 60)

    feed(pid, :down)
    assert audits(TmuxEventsFlapWatch.degraded_action()) == []

    assert_receive_audit(TmuxEventsFlapWatch.degraded_action(), 500)
    assert [event] = audits(TmuxEventsFlapWatch.degraded_action())
    assert event.metadata["reason"] == "listener_down"
  end

  test "never-connected boot (only reconnect_attempts) raises after down_ms" do
    pid = start_watch(threshold: 10, window_ms: 60_000, down_ms: 60)

    # Listener starts, never attaches: only reconnect_attempt telemetry, no
    # :up and possibly no :down — the likeliest canary failure mode.
    feed(pid, :reconnect_attempt)
    feed(pid, :reconnect_attempt)

    assert_receive_audit(TmuxEventsFlapWatch.degraded_action(), 500)
    assert [event] = audits(TmuxEventsFlapWatch.degraded_action())
    assert event.metadata["reason"] == "listener_down"
  end

  test "up before down_ms cancels the pending down raise" do
    pid = start_watch(threshold: 10, window_ms: 60_000, down_ms: 80)

    feed(pid, :down)
    feed(pid, :up)
    # Wall-clock settle past down_ms (80); receive-after, not Process.sleep.
    receive do
    after
      150 -> :ok
    end

    _ = :sys.get_state(pid)

    assert audits(TmuxEventsFlapWatch.degraded_action()) == []
  end

  test "thresholds are configurable via start opts" do
    pid = start_watch(threshold: 1, window_ms: 60_000)

    feed(pid, :down)
    assert [event] = audits(TmuxEventsFlapWatch.degraded_action())
    assert event.metadata["threshold"] == 1
  end

  test "flag off is a no-op (no audit)" do
    Application.put_env(:dev_ide, :tmux_events, false)
    pid = start_watch(threshold: 1)

    feed(pid, :down)
    assert audits(TmuxEventsFlapWatch.degraded_action()) == []
  end

  test "telemetry path raises via :telemetry.execute" do
    name = :"tmux_flap_tel_#{System.unique_integer([:positive])}"

    start_supervised!(
      {TmuxEventsFlapWatch,
       name: name, attach?: true, threshold: 2, window_ms: 60_000, sustained_ms: 60_000}
    )

    # Wait for attach.
    _ = :sys.get_state(name)

    for _ <- 1..2 do
      :telemetry.execute(
        [:tmux_ctl, :events, :listener],
        %{count: 1, reconnects: 1, reconnects_in_window: 1},
        %{event: :down, label: "tel", reconnects: 1}
      )
    end

    # Flush casts.
    _ = :sys.get_state(name)
    assert [_] = audits(TmuxEventsFlapWatch.degraded_action())
  end

  defp assert_receive_audit(action, timeout) do
    DevIDE.Test.Eventually.await(
      fn ->
        case audits(action) do
          [_ | _] = list -> list
          [] -> false
        end
      end,
      timeout_ms: timeout,
      interval_ms: 10,
      message: "expected audit action #{action} within #{timeout}ms"
    )
  end
end
