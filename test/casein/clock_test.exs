defmodule Casein.ClockTest do
  use ExUnit.Case, async: false

  alias Casein.Clock

  describe "real mode" do
    test "send_after is wall-clock Process.send_after" do
      refute Clock.virtual?()
      ref = Clock.send_after(self(), :real, 10)
      assert is_reference(ref)
      assert_receive :real, 200
    end
  end

  describe "virtual mode" do
    setup do
      pid = start_supervised!(Casein.Clock.Scheduler)
      %{scheduler: pid}
    end

    test "now starts at zero and step advances to the next due time" do
      assert Clock.virtual?()
      assert Clock.now_ms() == 0

      Clock.send_after(self(), :later, 40)
      assert {:ok, %{msg: :later, due_ms: 40, seq: 1}} = Clock.step()
      assert Clock.now_ms() == 40
      assert_receive :later, 50
      assert :empty = Clock.step()
    end

    test "same-ms timers fire in schedule sequence, not map order" do
      traces =
        for _ <- 1..20 do
          Clock.send_after(self(), :a, 10)
          Clock.send_after(self(), :b, 10)
          Clock.send_after(self(), :c, 10)

          msgs =
            for _ <- 1..3 do
              assert {:ok, info} = Clock.step()
              msg = info.msg
              assert_receive ^msg, 50
              msg
            end

          assert Clock.advance_to(Clock.now_ms() + 1) == {:ok, []}
          msgs
        end

      assert Enum.uniq(traces) == [[:a, :b, :c]]
    end

    test "cancel_timer drops a pending virtual timer" do
      ref = Clock.send_after(self(), :nope, 25)
      assert Clock.cancel_timer(ref) == 25
      assert :empty = Clock.step()
      refute_receive :nope, 30
    end

    test "advance_to fires due timers in (due_ms, seq) order and parks now" do
      Clock.send_after(self(), :a, 5)
      Clock.send_after(self(), :b, 15)
      Clock.send_after(self(), :c, 15)

      assert {:ok, fired} = Clock.advance_to(10)
      assert Enum.map(fired, & &1.msg) == [:a]
      assert Clock.now_ms() == 10
      assert_receive :a, 50

      assert {:ok, %{msg: :b, due_ms: 15}} = Clock.step()
      assert {:ok, %{msg: :c, due_ms: 15}} = Clock.step()
    end

    test "advance_to refuses to move backwards" do
      assert {:ok, []} = Clock.advance_to(8)
      assert {:error, {:target_behind, 8, 3}} = Clock.advance_to(3)
    end
  end
end
