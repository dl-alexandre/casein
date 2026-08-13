defmodule Casein.Runtimes.LifecycleSizeTripwire do
  @moduledoc """
  Periodic size check for `runtime_lifecycle_events`.

  A comment in `EctoAdapter.events_for/1` said "if this ever exceeds ~500 in
  prod" — it exceeded that 1_023 times and never fired, because a comment is
  not a monitor. This check counts rows and per-runtime maxima and emits
  `runtime.lifecycle_events_oversized` when either crosses threshold.
  """

  import Ecto.Query

  require Logger

  alias Casein.Audit
  alias Casein.Repo
  alias Casein.Runtimes.{LifecycleEventRow, LifecycleEvents}

  @spec check_now(keyword()) :: %{
          table_rows: non_neg_integer(),
          max_per_runtime: non_neg_integer(),
          oversized_runtimes: non_neg_integer(),
          fired?: boolean()
        }
  def check_now(opts \\ []) do
    if ecto_adapter?() do
      do_check(opts)
    else
      %{table_rows: 0, max_per_runtime: 0, oversized_runtimes: 0, fired?: false}
    end
  end

  defp do_check(opts) do
    table_limit = Keyword.get(opts, :table_limit, table_row_tripwire())
    per_runtime_limit = Keyword.get(opts, :per_runtime_limit, per_runtime_tripwire())
    emit? = Keyword.get(opts, :emit, true)

    table_rows = Repo.aggregate(LifecycleEventRow, :count)

    per_runtime =
      LifecycleEventRow
      |> group_by([e], e.runtime_id)
      |> select([e], %{runtime_id: e.runtime_id, count: count(e.id)})
      |> having([e], count(e.id) > ^per_runtime_limit)
      |> Repo.all()

    max_per_runtime =
      case per_runtime do
        [] ->
          LifecycleEventRow
          |> group_by([e], e.runtime_id)
          |> select([e], count(e.id))
          |> order_by([e], desc: count(e.id))
          |> limit(1)
          |> Repo.one()
          |> Kernel.||(0)

        rows ->
          rows |> Enum.map(& &1.count) |> Enum.max()
      end

    fired? = table_rows > table_limit or per_runtime != []

    if fired? do
      Logger.warning(
        "[lifecycle-tripwire] runtime_lifecycle_events oversized " <>
          "table_rows=#{table_rows} table_limit=#{table_limit} " <>
          "max_per_runtime=#{max_per_runtime} per_runtime_limit=#{per_runtime_limit} " <>
          "oversized_runtimes=#{length(per_runtime)}"
      )

      if emit?,
        do: emit_alarm(table_rows, table_limit, max_per_runtime, per_runtime_limit, per_runtime)
    end

    %{
      table_rows: table_rows,
      max_per_runtime: max_per_runtime,
      oversized_runtimes: length(per_runtime),
      fired?: fired?
    }
  end

  defp emit_alarm(table_rows, table_limit, max_per_runtime, per_runtime_limit, per_runtime) do
    Audit.emit!(%{
      action: "runtime.lifecycle_events_oversized",
      workspace_id: "platform",
      target_type: "table",
      target_ref: "runtime_lifecycle_events",
      metadata: %{
        "table_rows" => table_rows,
        "table_limit" => table_limit,
        "max_per_runtime" => max_per_runtime,
        "per_runtime_limit" => per_runtime_limit,
        "oversized_runtimes" => length(per_runtime),
        "sample_runtime_ids" => Enum.map(Enum.take(per_runtime, 10), & &1.runtime_id)
      }
    })
  end

  defp table_row_tripwire do
    Application.get_env(
      :casein,
      :runtime_lifecycle_table_row_tripwire,
      LifecycleEvents.table_row_tripwire()
    )
  end

  defp per_runtime_tripwire do
    Application.get_env(
      :casein,
      :runtime_lifecycle_per_runtime_tripwire,
      LifecycleEvents.per_runtime_tripwire()
    )
  end

  defp ecto_adapter? do
    Application.get_env(:casein, :runtimes_adapter) == Casein.Runtimes.EctoAdapter
  end
end
