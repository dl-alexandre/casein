defmodule Casein.Runtimes.LifecycleEventsTest do
  use Casein.DataCase, async: false

  alias Casein.Audit
  alias Casein.Repo
  alias Casein.Runtimes

  alias Casein.Runtimes.{
    LifecycleEventRow,
    LifecycleEvents,
    LifecycleRetention,
    LifecycleSizeTripwire
  }

  alias Casein.Test.RuntimeSeed

  setup do
    Casein.Runtimes.EctoAdapter.clear()
    Audit.clear()

    prev_runtime = Application.get_env(:casein, :runtimes_adapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.EctoAdapter)

    on_exit(fn ->
      Casein.Runtimes.EctoAdapter.clear()
      Audit.clear()

      if prev_runtime,
        do: Application.put_env(:casein, :runtimes_adapter, prev_runtime),
        else: Application.delete_env(:casein, :runtimes_adapter)
    end)

    :ok
  end

  test "events_for never returns more than the hard cap, even when asked" do
    runtime = seed_runtime("rt-cap")
    insert_events(runtime, 2_050, "runtime_heartbeat")

    events = Runtimes.events_for(runtime.id, limit: 99_999)
    assert length(events) == LifecycleEvents.max_page_limit()

    page = Runtimes.events_page(runtime.id, limit: 99_999)
    assert page.truncated?
    assert page.total == 2_051
    assert page.limit == LifecycleEvents.max_page_limit()

    assert page.banner ==
             "Showing latest #{LifecycleEvents.max_page_limit()} of 2051 lifecycle events"
  end

  test "events_page defaults to the documented 500 tripwire and stays chronological" do
    runtime = seed_runtime("rt-page")
    insert_events(runtime, 520, "runtime_heartbeat")

    page = Runtimes.events_page(runtime.id)
    assert page.limit == 500
    assert page.total == 521
    assert page.truncated?
    assert page.banner == "Showing latest 500 of 521 lifecycle events"
    assert length(page.events) == 500
    assert List.last(page.events).event == "runtime_heartbeat"
    refute Enum.any?(page.events, &(&1.event == "runtime_requested"))

    times = Enum.map(page.events, & &1.inserted_at)
    assert times == Enum.sort(times, {:asc, DateTime})
  end

  test "retention deletes aged heartbeats and keeps lifecycle transitions" do
    runtime = seed_runtime("rt-retain")
    now = DateTime.utc_now()
    old = DateTime.add(now, -14 * 86_400, :second)
    recent = DateTime.add(now, -2 * 86_400, :second)

    insert_event(runtime, "runtime_heartbeat", old)
    insert_event(runtime, "runtime_heartbeat", recent)
    insert_event(runtime, "runtime_expired", old)

    result = LifecycleRetention.sweep_now(older_than: DateTime.add(now, -7 * 86_400, :second))

    assert result.deleted == 1
    assert result.dry_run == false

    names = runtime.id |> Runtimes.events_for() |> Enum.map(& &1.event)
    assert Enum.sort(names) == ["runtime_expired", "runtime_heartbeat", "runtime_requested"]
    assert Enum.count(names, &(&1 == "runtime_heartbeat")) == 1
  end

  test "size tripwire fires when a runtime crosses the documented ~500 count" do
    runtime = seed_runtime("rt-trip")
    insert_events(runtime, LifecycleEvents.per_runtime_tripwire(), "runtime_heartbeat")

    result =
      LifecycleSizeTripwire.check_now(
        table_limit: 1_000_000,
        per_runtime_limit: LifecycleEvents.per_runtime_tripwire()
      )

    assert result.fired?
    assert result.max_per_runtime > LifecycleEvents.per_runtime_tripwire()
    assert result.oversized_runtimes == 1

    assert Enum.any?(Audit.list(), fn event ->
             event.action == "runtime.lifecycle_events_oversized"
           end)
  end

  test "size tripwire stays quiet under the documented thresholds" do
    runtime = seed_runtime("rt-quiet")
    insert_events(runtime, 3, "runtime_heartbeat")

    result =
      LifecycleSizeTripwire.check_now(
        table_limit: 1_000_000,
        per_runtime_limit: LifecycleEvents.per_runtime_tripwire()
      )

    refute result.fired?
    refute Enum.any?(Audit.list(), &(&1.action == "runtime.lifecycle_events_oversized"))
  end

  defp seed_runtime(id) do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-lifecycle-events",
        runtime_id: id,
        status: "provisioned",
        worktree_path: "/tmp/#{id}"
      )

    runtime
  end

  defp insert_events(runtime, count, event) do
    now = DateTime.utc_now()

    for index <- 1..count do
      insert_event(runtime, event, DateTime.add(now, index, :second))
    end
  end

  defp insert_event(runtime, event, inserted_at) do
    Repo.insert!(%LifecycleEventRow{
      id: Ecto.UUID.generate(),
      runtime_id: runtime.id,
      workspace_id: runtime.workspace_id,
      event: event,
      from_status: runtime.status,
      to_status: runtime.status,
      metadata: %{},
      inserted_at: inserted_at
    })
  end
end
