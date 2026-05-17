defmodule DevIDE.Terminals.TmuxJanitorTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.TmuxJanitor

  # The janitor is started in the application supervision tree. Tests just
  # reach in via the public API and inspect __state__/0. Each test uses a
  # session name unique enough that parallel test runs don't collide.

  setup do
    # Disable idle GC by default; tests that need a timer reconfigure it.
    Application.delete_env(:dev_ide, :tmux_idle_seconds)
    :ok
  end

  defp session_name(suffix \\ ""), do: "devide_jtest_" <> unique(suffix)
  defp unique(s), do: s <> Integer.to_string(System.unique_integer([:positive]))

  test "subscribe registers the calling pid and clears any pending kill" do
    s = session_name()

    TmuxJanitor.subscribe(s)
    state = TmuxJanitor.__state__()

    entry = Map.fetch!(state.sessions, s)
    assert MapSet.member?(entry.subscribers, self())
    assert entry.kill_timer == nil
  end

  test "unsubscribe with idle disabled removes the session entry immediately" do
    s = session_name()

    TmuxJanitor.subscribe(s)
    TmuxJanitor.unsubscribe(s)
    # Cast — give it a moment to settle.
    _ = TmuxJanitor.__state__()

    refute Map.has_key?(TmuxJanitor.__state__().sessions, s)
  end

  test "two subscribers from different pids keep the session alive until both leave" do
    s = session_name()
    parent = self()

    TmuxJanitor.subscribe(s)

    {:ok, pid} =
      Task.start_link(fn ->
        TmuxJanitor.subscribe(s)
        send(parent, :subscribed)

        receive do
          :leave -> TmuxJanitor.unsubscribe(s)
        end
      end)

    assert_receive :subscribed, 500
    # Sync — sending a call after a cast ensures the cast has been processed.
    _ = TmuxJanitor.__state__()

    entry = TmuxJanitor.__state__().sessions[s]
    assert MapSet.size(entry.subscribers) == 2

    send(pid, :leave)
    Process.sleep(50)
    entry = TmuxJanitor.__state__().sessions[s]
    assert MapSet.size(entry.subscribers) == 1

    TmuxJanitor.unsubscribe(s)
    _ = TmuxJanitor.__state__()
    refute Map.has_key?(TmuxJanitor.__state__().sessions, s)
  end

  test ":DOWN from a subscriber is treated like unsubscribe" do
    s = session_name()
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        TmuxJanitor.subscribe(s)
        send(parent, :subscribed)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :subscribed, 500
    _ = TmuxJanitor.__state__()

    assert MapSet.size(TmuxJanitor.__state__().sessions[s].subscribers) == 1

    send(pid, :die)
    # Wait for the monitor to fire and the cast to be processed.
    Process.sleep(50)
    _ = TmuxJanitor.__state__()

    refute Map.has_key?(TmuxJanitor.__state__().sessions, s)
  end

  test "kill_idle fires after the configured delay and removes the entry" do
    Application.put_env(:dev_ide, :tmux_idle_seconds, 1)
    s = session_name("kill_")

    TmuxJanitor.subscribe(s)
    TmuxJanitor.unsubscribe(s)

    # Idle = 1 second; give it a generous margin for the tmux kill shell out
    # (Tmux.kill sleeps ~50ms for non-existent sessions).
    Process.sleep(1500)
    _ = TmuxJanitor.__state__()

    refute Map.has_key?(TmuxJanitor.__state__().sessions, s)
  end

  test "resubscribing before the kill fires cancels the timer" do
    Application.put_env(:dev_ide, :tmux_idle_seconds, 60)
    s = session_name("cancel_")

    TmuxJanitor.subscribe(s)
    TmuxJanitor.unsubscribe(s)

    entry = TmuxJanitor.__state__().sessions[s]
    assert is_reference(entry.kill_timer)

    TmuxJanitor.subscribe(s)
    entry = TmuxJanitor.__state__().sessions[s]
    assert entry.kill_timer == nil
    assert MapSet.member?(entry.subscribers, self())
  end

  test "session name without devide_ prefix is rejected at subscribe time" do
    # Guards against accidentally tracking — and later killing — the
    # dev-time `phoenix` or `mock_manager` tmux sessions.
    foreign = "phoenix_pretend_" <> unique("")

    assert TmuxJanitor.subscribe(foreign) == :ok
    refute Map.has_key?(TmuxJanitor.__state__().sessions, foreign)
  end
end
