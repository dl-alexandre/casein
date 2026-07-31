defmodule Casein.Access.ReconnectPolicyTest do
  use ExUnit.Case, async: true

  alias Casein.Access.ReconnectPolicy, as: Policy

  describe "backoff" do
    test "grows exponentially and caps" do
      delays = Enum.map(1..10, &Policy.next_delay_ms/1)

      assert Enum.take(delays, 4) == [500, 1_000, 2_000, 4_000]
      assert Enum.all?(delays, &(&1 <= Policy.max_delay_ms()))
      assert List.last(delays) == Policy.max_delay_ms()
    end

    test "is monotonically non-decreasing" do
      delays = Enum.map(1..12, &Policy.next_delay_ms/1)
      assert delays == Enum.sort(delays)
    end

    test "a caller that has not incremented yet still gets a sane delay" do
      assert Policy.next_delay_ms(0) == Policy.next_delay_ms(1)
      assert Policy.next_delay_ms(-5) == Policy.next_delay_ms(1)
    end
  end

  describe "interrupts" do
    test "connectivity, activation, credentials, and user retry all cut the wait" do
      for event <- [:connectivity_change, :app_activation, :credential_change, :user_retry] do
        assert Policy.interrupt?(event), "#{event} must interrupt the backoff wait"
      end
    end

    test "an unrelated event does not" do
      refute Policy.interrupt?(:heartbeat)
    end
  end

  describe "offline waits do not consume attempts" do
    test "an offline wait leaves the attempt count untouched" do
      assert %{attempt: 3} = Policy.next_wait(3, false)
      refute Policy.consumes_attempt?(false)
    end

    test "an online wait advances the attempt count" do
      assert %{attempt: 4, delay_ms: delay} = Policy.next_wait(3, true)
      assert delay == Policy.next_delay_ms(4)
      assert Policy.consumes_attempt?(true)
    end

    test "repeated offline waits never push backoff toward the ceiling" do
      {attempt, delay} =
        Enum.reduce(1..20, {1, nil}, fn _i, {attempt, _delay} ->
          %{attempt: next, delay_ms: delay} = Policy.next_wait(attempt, false)
          {next, delay}
        end)

      assert attempt == 1

      assert delay == Policy.next_delay_ms(1),
             "20 offline waits must not behave like 20 failed attempts"
    end
  end

  describe "close handling" do
    test "an involuntary close keeps registration and retries" do
      assert %{retry?: true, keep_registration?: true} = Policy.on_close(:involuntary)
    end

    test "a deliberate teardown discards and does not retry" do
      assert %{retry?: false, keep_registration?: false} = Policy.on_close(:deliberate)
    end
  end

  describe "connected requires more than a listening socket" do
    test "socket open plus config success is connected" do
      assert Policy.connection_state(true, true) == :connected
    end

    test "socket open with no config success is only connecting" do
      assert Policy.connection_state(true, false) == :connecting,
             "a port that answers is not proof the app behind it is alive"
    end

    test "no socket is disconnected regardless of config" do
      assert Policy.connection_state(false, true) == :disconnected
      assert Policy.connection_state(false, false) == :disconnected
    end
  end
end
