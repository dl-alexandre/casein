defmodule DevIDE.Signals.ObanContextTest do
  use ExUnit.Case, async: true

  import Oban.Testing

  alias DevIDE.Signals.Context
  alias DevIDE.Signals.ObanContext
  alias DevIDE.Signals.ObanMiddleware
  alias DevIDE.Test.ObanSignalsWorker

  test "prepare_job stamps the active snapshot into job meta" do
    Context.with_new(fn ->
      trace_id = Context.current().trace_id
      changeset = ObanMiddleware.new_job(ObanSignalsWorker, %{})
      meta = Ecto.Changeset.get_change(changeset, :meta, %{})

      assert get_in(meta, [ObanContext.meta_key(), "trace_id"]) == trace_id
    end)
  end

  test "perform_job restores context from job meta for audit stamping" do
    Context.with_new(fn ->
      trace_id = Context.current().trace_id

      job =
        build_job(ObanSignalsWorker, %{},
          meta: %{
            ObanContext.meta_key() => %{
              "trace_id" => trace_id,
              "span_id" => String.duplicate("a", 16)
            }
          }
        )

      stamped =
        ObanMiddleware.perform_job(job, fn _job ->
          Context.stamp(%{action: "oban.test"})
        end)

      assert stamped.metadata["correlation_id"] == trace_id
    end)

    assert Context.current() == nil
  end

  test "ObanWorker execute/1 runs under the stamped context" do
    Context.with_new(fn ->
      trace_id = Context.current().trace_id

      job =
        build_job(ObanSignalsWorker, %{},
          meta: %{ObanContext.meta_key() => ObanContext.encode(Context.current())}
        )

      assert :ok = perform_job(job, [])

      assert Process.get({ObanSignalsWorker, :correlation_id}) == trace_id
    end)
  end
end