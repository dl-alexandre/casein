defmodule Casein.Workspaces.Reconciler do
  @moduledoc """
  Retires workspace records the devbox manager has stopped listing.

  Casein persists a `WorkspaceRecord` for every workspace it observes, but has
  no delete path of its own — the milc-devbox manager owns workspace lifecycle
  (`docs/architecture.md`, "Start/stop/delete workspace | Manager"). When a
  workspace is deleted there, the manager tears down its containers, Caddy
  routes, git worktree and DNS, and drops its own entry; nothing tells Casein.
  The record then lingers in the sidebar forever, because `last_seen_at` is
  written on every sync but nothing ever reads it for expiry. This sweep closes
  that loop by marking such records stale, which the sidebar already filters.

  ## Devbox-specific by construction

  The sweep only runs when the configured source is
  `Casein.WorkspaceSource.Manager`. That is not a convenience check — the
  inference "absent from the listing ⇒ deleted" is only sound against a
  service that is authoritative for the whole set. It is false for the default
  `Casein.WorkspaceSource.Local`, which derives workspaces from a directory
  walk: an unmounted root or a transient `File.ls` error there looks exactly
  like a mass deletion, and `Local` additionally serves a synthetic `home`
  workspace that no walk of the root will ever return.

  Within devbox the manager is authoritative but not unconditionally global:
  `GET /api/workspaces` filters to the caller's own user unless the caller is
  an admin passing `all=true`. On a shared box this is the difference between
  retiring one deleted workspace and retiring every other developer's. The
  sweep therefore resolves its listing scope from the manager's own identity
  endpoint before drawing any conclusion, and `Plan` only retires records whose
  owner that scope actually covered.

  ## Rollout

  Gated by `:workspace_reconciler_enabled` (default `false`) and
  `:workspace_reconciler_dry_run` (default `true`), mirroring
  `Casein.Runtimes.Reaper`: enable first to log the plan, then clear the dry
  run to let it write.

  Retirement is reversible and non-destructive — see `State.retire/1`. Reaping
  the *resources* a retired workspace leaves behind (its tmux sessions, its
  rows across the workspace-keyed tables) is deliberately not done here; that
  is destructive, needs its own gating, and belongs in a separate pass built on
  the retirement signal this one produces.
  """

  use GenServer

  require Logger

  alias Casein.Audit
  alias Casein.WorkspaceSource
  alias Casein.Workspaces.Reconciler.Plan
  alias Casein.Workspaces.State

  @default_sweep_interval_ms :timer.hours(1)
  @default_grace_ms :timer.minutes(30)
  @manager_source Casein.WorkspaceSource.Manager

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs a sweep in the calling process and returns its outcome.

  Accepts `:dry_run` to override the configured setting. This is the whole
  sweep — the GenServer only schedules it — so callers that need to observe or
  stub its HTTP (tests, a release RPC audit) do so without reaching through the
  server process.
  """
  @spec sweep(keyword()) :: map()
  def sweep(opts \\ []), do: do_sweep(opts)

  @doc """
  Runs a sweep on the server process and returns its outcome.

  The scheduled entry point's manual twin; prefer `sweep/1` unless the
  serialization against concurrent scheduled sweeps is what you want.
  """
  @spec sweep_now(keyword()) :: map()
  def sweep_now(opts \\ []) do
    GenServer.call(__MODULE__, {:sweep_now, opts}, 60_000)
  end

  @impl true
  def init(_opts) do
    Logger.info(
      "[workspace-reconciler] supervised under Casein.Supervision.PlatformServices " <>
        "enabled=#{enabled?()} dry_run=#{dry_run?()} source=#{inspect(WorkspaceSource.impl())}"
    )

    if enabled?(), do: schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:sweep_now, opts}, _from, state) do
    {:reply, do_sweep(opts), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = do_sweep([])
    if enabled?(), do: schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Sweep

  @spec do_sweep(keyword()) :: map()
  defp do_sweep(opts) do
    dry_run = Keyword.get(opts, :dry_run, dry_run?())

    with :ok <- check_source(),
         {:ok, scope} <- fetch_scope(),
         {:ok, listed} <- fetch_listing(),
         :ok <- check_non_empty(listed) do
      Plan.build(listed, State.list(),
        now: DateTime.utc_now(),
        grace_ms: grace_ms(),
        scope: scope
      )
      |> apply_plan(dry_run)
    else
      {:skip, reason} ->
        Logger.info("[workspace-reconciler] skipped: #{inspect(reason)}")
        %{status: :skipped, reason: reason, retired: []}
    end
  end

  # Only the manager source is authoritative about the full set of workspaces.
  defp check_source do
    case WorkspaceSource.impl() do
      @manager_source -> :ok
      other -> {:skip, {:source_not_manager, other}}
    end
  end

  defp fetch_scope do
    case @manager_source.listing_scope(auth()) do
      {:ok, scope} -> {:ok, scope}
      {:error, reason} -> {:skip, {:identity_probe_failed, reason}}
    end
  end

  defp fetch_listing do
    case @manager_source.list_all(auth()) do
      {:ok, listed} -> {:ok, listed}
      {:error, reason} -> {:skip, {:listing_failed, reason}}
    end
  end

  # A manager that answers 200 with an empty list is far more likely to be
  # broken, mid-restart, or reading an empty data file than to be reporting
  # that every workspace on the box was deleted. Refuse to act on it.
  defp check_non_empty([]), do: {:skip, :empty_listing}
  defp check_non_empty(_listed), do: :ok

  defp apply_plan(%Plan{retire: []} = plan, _dry_run) do
    Logger.info(
      "[workspace-reconciler] nothing to retire " <>
        "scope=#{inspect(plan.scope)} listed=#{plan.listed} skipped=#{inspect(plan.skipped)}"
    )

    %{status: :ok, retired: [], skipped: plan.skipped, scope: plan.scope, listed: plan.listed}
  end

  defp apply_plan(%Plan{} = plan, true) do
    ids = Enum.map(plan.retire, & &1.external_id)

    Logger.info(
      "[workspace-reconciler] dry-run: would retire #{length(ids)} record(s) " <>
        "#{inspect(ids)} scope=#{inspect(plan.scope)} listed=#{plan.listed}"
    )

    %{
      status: :dry_run,
      retired: ids,
      skipped: plan.skipped,
      scope: plan.scope,
      listed: plan.listed
    }
  end

  defp apply_plan(%Plan{} = plan, false) do
    retired = Enum.flat_map(plan.retire, &retire_record(&1, plan))

    Logger.info(
      "[workspace-reconciler] retired #{length(retired)} record(s) #{inspect(retired)} " <>
        "scope=#{inspect(plan.scope)} listed=#{plan.listed} skipped=#{inspect(plan.skipped)}"
    )

    %{
      status: :ok,
      retired: retired,
      skipped: plan.skipped,
      scope: plan.scope,
      listed: plan.listed
    }
  end

  defp retire_record(record, plan) do
    case State.retire(record.external_id) do
      {:ok, _updated} ->
        Audit.emit!(%{
          workspace_id: record.external_id,
          action: "workspace.retired",
          source: "workspace_reconciler",
          target_type: "workspace_record",
          target_ref: record.external_id,
          reason: :absent_from_source,
          metadata: %{
            "user" => record.user,
            "host_path" => record.host_path,
            "last_seen_at" => record.last_seen_at && DateTime.to_iso8601(record.last_seen_at),
            "listing_scope" => inspect(plan.scope),
            "listed_count" => plan.listed
          }
        })

        [record.external_id]

      {:error, reason} ->
        Logger.warning(
          "[workspace-reconciler] failed to retire #{record.external_id}: #{inspect(reason)}"
        )

        []
    end
  end

  ## Config

  defp schedule_sweep, do: Process.send_after(self(), :sweep, sweep_interval_ms())

  defp enabled?, do: Application.get_env(:casein, :workspace_reconciler_enabled, false)

  defp dry_run?, do: Application.get_env(:casein, :workspace_reconciler_dry_run, true)

  defp sweep_interval_ms do
    Application.get_env(
      :casein,
      :workspace_reconciler_sweep_interval_ms,
      @default_sweep_interval_ms
    )
  end

  # How long a record must go unlisted before it is retired. Absorbs a manager
  # returning a partial listing for one sweep: `last_seen_at` is refreshed by
  # every `Workspaces.list/2`, so a workspace that is genuinely still there
  # cannot stay unseen across the window.
  #
  # Note that every `State` write refreshes `last_seen_at`, not just source
  # syncs — a mode change or isolation probe on an already-deleted workspace
  # defers its retirement by one window. That errs toward keeping a record,
  # which is the harmless direction, and clears on the next sweep.
  defp grace_ms,
    do: Application.get_env(:casein, :workspace_reconciler_grace_ms, @default_grace_ms)

  # Identity the manager sees us as. An admin identity widens the listing to
  # the whole box; without one the sweep still works, scoped to that user.
  defp auth do
    Application.get_env(:casein, :workspace_reconciler_admin_email) ||
      Application.get_env(:casein, :manager_user_email)
  end
end
