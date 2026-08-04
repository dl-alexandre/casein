defmodule DevideMob.OutboxTest do
  use Mob.ScreenCase, async: false

  alias DevideMob.Outbox
  alias DevideMob.SessionConfig

  setup do
    SessionConfig.clear_all()
    :ok
  end

  test "queued instructions survive as durable entries with an idempotency key" do
    entry = Outbox.enqueue("ws-1", "run the tests")

    assert entry.workspace_id == "ws-1"
    assert entry.text == "run the tests"
    assert entry.submit
    assert entry.attempts == 0
    assert is_binary(entry.request_id)

    assert [^entry] = Outbox.list()
    assert Outbox.count("ws-1") == 1
    assert Outbox.count("ws-2") == 0
  end

  test "an accepted send drops its entry" do
    entry = Outbox.enqueue("ws-1", "run the tests")
    Outbox.enqueue("ws-1", "and lint")

    :ok = Outbox.ack(entry.request_id)

    assert [%{text: "and lint"}] = Outbox.list()
  end

  test "a failed attempt is counted, and an entry is dropped once it gives up" do
    entry = Outbox.enqueue("ws-1", "run the tests")

    for attempt <- 1..(Outbox.max_attempts() - 1) do
      assert {:retrying, retried} = Outbox.fail(entry.request_id)
      assert retried.attempts == attempt
    end

    assert {:dropped, dropped} = Outbox.fail(entry.request_id)
    assert dropped.attempts == Outbox.max_attempts()
    assert Outbox.list() == []
  end

  test "failing an unknown request is a no-op rather than an error" do
    assert Outbox.fail("never-queued") == :unknown
  end

  test "the queue is capped so a long outage cannot replay a whole morning" do
    for index <- 1..25, do: Outbox.enqueue("ws-1", "instruction #{index}")

    entries = Outbox.list()

    assert length(entries) == 20
    # The oldest are dropped, not the newest.
    assert List.first(entries).text == "instruction 6"
    assert List.last(entries).text == "instruction 25"
  end
end
