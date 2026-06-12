defmodule DevIDE.Runners.ExpireLeasesWorker do
  @moduledoc """
  Oban worker that reclaims runner assignment leases held by silent or dead runners.

  Replaces the former `ExpiryScheduler` GenServer tick. The worker reschedules
  itself after each run so the interval stays configurable via
  `:lease_expiry_interval_ms` (default 30s).
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias DevIDE.Runners

  @default_interval_ms 30_000

  @doc "Returns the configured tick interval in milliseconds."
  @spec interval_ms() :: pos_integer()
  def interval_ms,
    do: Application.get_env(:dev_ide, :lease_expiry_interval_ms, @default_interval_ms)

  @doc """
  Ensures a future job exists. Safe to call on every boot — no-ops when one is
  already scheduled, available, executing, or retryable.
  """
  @spec ensure_scheduled() :: :ok
  def ensure_scheduled do
    import Ecto.Query

    worker = inspect(__MODULE__)

    query =
      from(j in Oban.Job,
        where: j.worker == ^worker,
        where: j.state in ["scheduled", "available", "executing", "retryable"]
      )

    case DevIde.Repo.one(query) do
      nil -> schedule_next()
      _ -> :ok
    end
  end

  @doc "Enqueue the next lease-expiry tick."
  @spec schedule_next() :: :ok
  def schedule_next do
    %{}
    |> new(schedule_in: max(div(interval_ms(), 1000), 1))
    |> Oban.insert()

    :ok
  end

  @impl Oban.Worker
  def perform(_job) do
    expired = Runners.expire_leases(DateTime.utc_now())

    if expired != [] do
      Logger.info("expired #{length(expired)} runner lease(s)")
    end

    schedule_next()
    :ok
  end
end
