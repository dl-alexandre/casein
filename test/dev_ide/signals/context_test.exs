defmodule DevIDE.Signals.ContextTest do
  use ExUnit.Case, async: true

  alias DevIDE.Signals.Context

  test "with_new installs a fresh context and clears it after" do
    assert Context.current() == nil

    trace_id =
      Context.with_new(fn ->
        ctx = Context.current()
        assert is_binary(ctx.trace_id)
        assert ctx.causation_id == nil
        ctx.trace_id
      end)

    assert is_binary(trace_id)
    assert Context.current() == nil
  end

  test "nested with_new restores the outer context" do
    Context.with_new(fn ->
      outer = Context.current()

      Context.with_new(fn ->
        refute Context.current().trace_id == outer.trace_id
      end)

      assert Context.current() == outer
    end)
  end

  test "snapshot survives a process boundary via with_snapshot" do
    Context.with_new(fn ->
      snap = Context.snapshot()

      inner_trace_id =
        Task.async(fn ->
          assert Context.current() == nil
          Context.with_snapshot(snap, fn -> Context.current().trace_id end)
        end)
        |> Task.await()

      assert inner_trace_id == snap.trace_id
    end)
  end

  test "with_snapshot with nil runs bare" do
    assert Context.with_snapshot(nil, fn -> Context.current() end) == nil
  end

  test "advance keeps the correlation and points causation at the event" do
    Context.with_new(fn ->
      before = Context.current()
      :ok = Context.advance("evt-1")
      after_ctx = Context.current()

      assert after_ctx.trace_id == before.trace_id
      assert after_ctx.causation_id == "evt-1"
    end)
  end

  test "advance without a context is a no-op" do
    assert Context.current() == nil
    assert :ok = Context.advance("evt-1")
    assert Context.current() == nil
  end

  test "stamp is the identity without a context" do
    attrs = %{action: "x", metadata: %{"a" => 1}}
    assert Context.stamp(attrs) == attrs
  end

  test "stamp adds correlation and (after advance) causation without overwriting" do
    Context.with_new(fn ->
      ctx = Context.current()

      stamped = Context.stamp(%{action: "x"})
      assert stamped.metadata["correlation_id"] == ctx.trace_id
      refute Map.has_key?(stamped.metadata, "causation_id")

      :ok = Context.advance("evt-1")
      stamped = Context.stamp(%{action: "y", metadata: %{"a" => 1}})
      assert stamped.metadata["correlation_id"] == ctx.trace_id
      assert stamped.metadata["causation_id"] == "evt-1"
      assert stamped.metadata["a"] == 1

      explicit = Context.stamp(%{action: "z", metadata: %{"correlation_id" => "keep"}})
      assert explicit.metadata["correlation_id"] == "keep"
    end)
  end
end
