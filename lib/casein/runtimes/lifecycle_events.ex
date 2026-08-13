defmodule Casein.Runtimes.LifecycleEvents do
  @moduledoc """
  Write-volume guards for `runtime_lifecycle_events`.

  Prod measured 2026-08-13: this table was **4864 MB of a 5283 MB database
  (92.1%)**, 6_448_733 rows, ~93% `runtime_heartbeat`. Median events per
  runtime was 1; the tail hit 77_552. That is a write-volume defect, not an
  indexing one — do not add indexes here to "fix" growth (#926 owns indexes
  separately). Guard the write, prune heartbeats, and refuse an unbounded
  `events_for/1`.
  """

  @default_page_limit 500
  @max_page_limit 2_000
  @per_runtime_tripwire 500
  @table_row_tripwire 100_000
  @heartbeat_retention_days 7

  @type page :: %{
          events: [Casein.Runtimes.LifecycleEvent.t()],
          limit: pos_integer(),
          total: non_neg_integer(),
          truncated?: boolean(),
          banner: String.t() | nil
        }

  @spec default_page_limit() :: pos_integer()
  def default_page_limit, do: @default_page_limit

  @spec max_page_limit() :: pos_integer()
  def max_page_limit, do: @max_page_limit

  @spec per_runtime_tripwire() :: pos_integer()
  def per_runtime_tripwire, do: @per_runtime_tripwire

  @spec table_row_tripwire() :: pos_integer()
  def table_row_tripwire, do: @table_row_tripwire

  @spec heartbeat_retention_days() :: pos_integer()
  def heartbeat_retention_days, do: @heartbeat_retention_days

  @spec clamp_limit(term()) :: pos_integer()
  def clamp_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @max_page_limit)
  end

  def clamp_limit(_limit), do: @default_page_limit

  @spec page([Casein.Runtimes.LifecycleEvent.t()], keyword()) :: page()
  def page(events, opts \\ []) when is_list(events) do
    limit = clamp_limit(Keyword.get(opts, :limit, @default_page_limit))
    total = length(events)

    kept =
      events
      |> Enum.sort_by(&event_recency/1, :desc)
      |> Enum.take(limit)
      |> Enum.reverse()

    wrap(kept, limit, total)
  end

  @spec wrap([Casein.Runtimes.LifecycleEvent.t()], pos_integer(), non_neg_integer()) :: page()
  def wrap(events, limit, total)
      when is_list(events) and is_integer(limit) and is_integer(total) do
    truncated? = total > limit

    %{
      events: events,
      limit: limit,
      total: total,
      truncated?: truncated?,
      banner: banner(truncated?, limit, total)
    }
  end

  defp banner(true, limit, total),
    do: "Showing latest #{limit} of #{total} lifecycle events"

  defp banner(false, _limit, _total), do: nil

  defp event_recency(%{inserted_at: %DateTime{} = at}),
    do: DateTime.to_unix(at, :microsecond)

  defp event_recency(_), do: 0
end
