defmodule Casein.Runtimes.LifecycleRetention do
  @moduledoc """
  Deletes aged `runtime_heartbeat` rows from `runtime_lifecycle_events`.

  Heartbeats are machine activity, not lifecycle. After the write guard in
  `Runtimes.observe_worktree/2` they should stop accumulating; this sweep
  drains the existing 6M-row tail. Non-heartbeat events are kept.

  Oban was dropped from prod, so the runtime reaper is the periodic home —
  not a new job table. No schema change: deletes only.
  """

  import Ecto.Query

  require Logger

  alias Casein.Repo
  alias Casein.Runtimes.{LifecycleEventRow, LifecycleEvents}

  @default_batch_size 10_000
  @default_max_batches 100

  @spec sweep_now(keyword()) :: %{
          deleted: non_neg_integer(),
          batches: non_neg_integer(),
          older_than: DateTime.t(),
          dry_run: boolean()
        }
  def sweep_now(opts \\ []) do
    older_than = Keyword.get(opts, :older_than, cutoff())
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    max_batches = Keyword.get(opts, :max_batches, @default_max_batches)
    dry_run? = Keyword.get(opts, :dry_run, dry_run?())

    if ecto_adapter?() do
      do_sweep(older_than, batch_size, max_batches, dry_run?)
    else
      %{deleted: 0, batches: 0, older_than: older_than, dry_run: dry_run?}
    end
  end

  defp do_sweep(older_than, _batch_size, _max_batches, true) do
    count =
      LifecycleEventRow
      |> stale_heartbeats(older_than)
      |> Repo.aggregate(:count)

    Logger.info(
      "[lifecycle-retention] dry-run: would delete #{count} runtime_heartbeat rows " <>
        "older than #{DateTime.to_iso8601(older_than)}"
    )

    %{deleted: 0, batches: 0, older_than: older_than, dry_run: true}
  end

  defp do_sweep(older_than, batch_size, max_batches, false) do
    {deleted, batches} = delete_batches(older_than, batch_size, max_batches, 0, 0)

    if deleted > 0 do
      Logger.info(
        "[lifecycle-retention] deleted #{deleted} runtime_heartbeat rows " <>
          "in #{batches} batches older_than=#{DateTime.to_iso8601(older_than)}"
      )
    end

    %{deleted: deleted, batches: batches, older_than: older_than, dry_run: false}
  end

  defp delete_batches(_older_than, _batch_size, max_batches, deleted, batches)
       when batches >= max_batches do
    {deleted, batches}
  end

  defp delete_batches(older_than, batch_size, max_batches, deleted, batches) do
    ids =
      LifecycleEventRow
      |> stale_heartbeats(older_than)
      |> select([e], e.id)
      |> limit(^batch_size)
      |> Repo.all()

    case ids do
      [] ->
        {deleted, batches}

      ids ->
        {count, _} =
          LifecycleEventRow
          |> where([e], e.id in ^ids)
          |> Repo.delete_all()

        delete_batches(
          older_than,
          batch_size,
          max_batches,
          deleted + count,
          batches + 1
        )
    end
  end

  defp stale_heartbeats(query, older_than) do
    where(query, [e], e.event == "runtime_heartbeat" and e.inserted_at < ^older_than)
  end

  defp cutoff do
    DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)
  end

  defp retention_days do
    Application.get_env(
      :casein,
      :runtime_lifecycle_heartbeat_retention_days,
      LifecycleEvents.heartbeat_retention_days()
    )
  end

  defp dry_run? do
    Application.get_env(:casein, :runtime_lifecycle_retention_dry_run, false)
  end

  defp ecto_adapter? do
    Application.get_env(:casein, :runtimes_adapter) == Casein.Runtimes.EctoAdapter
  end
end
