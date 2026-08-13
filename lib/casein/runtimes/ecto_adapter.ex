defmodule Casein.Runtimes.EctoAdapter do
  @moduledoc "Postgres-backed adapter for runtime orchestration records."

  @behaviour Casein.Runtimes

  import Ecto.Query

  alias Casein.Runtimes.{
    LifecycleEvent,
    LifecycleEventRow,
    LifecycleEvents,
    Runtime,
    RuntimeRow
  }

  alias Casein.Repo

  @impl true
  def create_runtime(%Runtime{} = runtime, %LifecycleEvent{} = event) do
    Repo.transaction(fn ->
      runtime =
        %RuntimeRow{}
        |> Ecto.Changeset.change(runtime_attrs(runtime))
        |> Repo.insert!()
        |> to_runtime()

      insert_event!(event)
      runtime
    end)
    |> case do
      {:ok, %Runtime{} = runtime} -> {:ok, runtime}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update_runtime(%Runtime{} = runtime, event) do
    # Upsert: if the row is missing (race, partial create, or adapter lag),
    # insert instead of crashing with Ecto.NoResultsError.
    Repo.transaction(fn ->
      row =
        case Repo.get(RuntimeRow, runtime.id) do
          nil ->
            %RuntimeRow{}
            |> Ecto.Changeset.change(runtime_attrs(runtime))
            |> Repo.insert!()

          existing ->
            existing
            |> Ecto.Changeset.change(runtime_attrs(runtime))
            |> Repo.update!()
        end

      if event, do: insert_event!(event)
      to_runtime(row)
    end)
    |> case do
      {:ok, %Runtime{} = runtime} -> {:ok, runtime}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_runtime(runtime_id) do
    case Repo.get(RuntimeRow, runtime_id) do
      nil -> :error
      row -> {:ok, to_runtime(row)}
    end
  end

  @impl true
  def list_runtimes(filters) do
    filters = filters || %{}
    limit = filters |> Map.get("limit", 500) |> clamp_limit()

    RuntimeRow
    |> filter(Map.delete(filters, "limit"))
    |> order_by([r], asc: r.created_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_runtime/1)
  end

  # One row per worktree path, newest first. `DISTINCT ON` collapses duplicate
  # rows in the database rather than paging them into the application, so a
  # workspace with a long runtime history still returns its *current* worktrees.
  @agent_worktree_limit 500

  @impl true
  def list_agent_worktree_runtimes(workspace_id, opts \\ [])

  def list_agent_worktree_runtimes(workspace_id, opts) when is_binary(workspace_id) do
    RuntimeRow
    |> where([r], r.workspace_id == ^workspace_id)
    |> where([r], r.isolation_mode == "worktree")
    |> where([r], r.status not in ["cleaned", "expired"])
    |> where([r], not is_nil(r.worktree_path))
    |> agent_worktree_scope(Keyword.get(opts, :latest_per_path, true))
    |> Repo.all()
    |> Enum.map(&to_runtime/1)
  end

  def list_agent_worktree_runtimes(_workspace_id, _opts), do: []

  defp agent_worktree_scope(query, true) do
    query
    |> distinct([r], r.worktree_path)
    |> order_by([r], asc: r.worktree_path, desc: r.created_at)
    |> limit(@agent_worktree_limit)
  end

  defp agent_worktree_scope(query, _latest_per_path?) do
    order_by(query, [r], desc: r.created_at)
  end

  @active_runtime_statuses ~w(active bound provisioned)

  @impl true
  def count_runtimes_by_workspace_ids([]), do: %{}

  def count_runtimes_by_workspace_ids(workspace_ids) when is_list(workspace_ids) do
    RuntimeRow
    |> where([r], r.workspace_id in ^workspace_ids)
    |> group_by([r], r.workspace_id)
    |> select([r], %{
      workspace_id: r.workspace_id,
      total: count(r.id),
      active: filter(count(r.id), r.status in ^@active_runtime_statuses)
    })
    |> Repo.all()
    |> Map.new(fn row -> {row.workspace_id, %{total: row.total, active: row.active}} end)
  end

  @impl true
  def list_runtimes_by_workspace_ids([]), do: []

  def list_runtimes_by_workspace_ids(workspace_ids) when is_list(workspace_ids) do
    RuntimeRow
    |> where([r], r.workspace_id in ^workspace_ids)
    |> order_by([r], asc: r.created_at)
    |> Repo.all()
    |> Enum.map(&to_runtime/1)
  end

  # #921: this used to be an unbounded Repo.all. Prod hit 77_552 events on one
  # runtime (1_023 runtimes past the ~500 comment tripwire) and materialising
  # that into the BEAM is the replay bug the comment warned about. Newest-first
  # LIMIT, chronological return, visible banner via events_page/2 — never a
  # silent cap, never unbounded. Indexing this table is not the fix.
  @impl true
  def events_for(runtime_id), do: events_page(runtime_id, []).events

  @impl true
  def events_page(runtime_id, opts \\ []) do
    limit =
      LifecycleEvents.clamp_limit(Keyword.get(opts, :limit, LifecycleEvents.default_page_limit()))

    total =
      LifecycleEventRow
      |> where([e], e.runtime_id == ^runtime_id)
      |> Repo.aggregate(:count)

    events =
      LifecycleEventRow
      |> where([e], e.runtime_id == ^runtime_id)
      |> order_by([e], desc: e.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.reverse()
      |> Enum.map(&to_event/1)

    LifecycleEvents.wrap(events, limit, total)
  end

  @impl true
  def clear do
    Repo.delete_all(LifecycleEventRow)
    Repo.delete_all(RuntimeRow)
    :ok
  end

  defp insert_event!(%LifecycleEvent{} = event) do
    %LifecycleEventRow{}
    |> Ecto.Changeset.change(event_attrs(event))
    |> Repo.insert!()
  end

  defp filter(query, filters) do
    Enum.reduce(filters, query, fn
      {"workspace_id", value}, query -> where(query, [r], r.workspace_id == ^value)
      {"host_id", value}, query -> where(query, [r], r.host_id == ^value)
      {"host", value}, query -> where(query, [r], r.host_id == ^value)
      # Status-alone is used by cleanup_expired/2 and the reaper. Served by
      # workspace_runtimes(status); existing indexes trail status (#926).
      {"status", value}, query -> where(query, [r], r.status == ^value)
      {"repo", value}, query -> where(query, [r], r.repo == ^value)
      {"branch", value}, query -> where(query, [r], r.branch == ^value)
      {"isolation_mode", value}, query -> where(query, [r], r.isolation_mode == ^value)
      {"branch_isolation", value}, query -> where(query, [r], r.isolation_mode == ^value)
      {"runtime_id", value}, query -> where(query, [r], r.id == ^value)
      {"id", value}, query -> where(query, [r], r.id == ^value)
      _, query -> query
    end)
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(1_000)
  defp clamp_limit(_limit), do: 500

  defp runtime_attrs(%Runtime{} = runtime) do
    %{
      id: runtime.id,
      workspace_id: runtime.workspace_id,
      host_id: runtime.host_id,
      os: runtime.os,
      repo: runtime.repo,
      branch: runtime.branch,
      worktree_path: runtime.worktree_path,
      runner_id: runtime.runner_id,
      session_id: runtime.session_id,
      tmux_session_id: runtime.tmux_session_id,
      isolation_mode: runtime.isolation_mode,
      status: runtime.status,
      capabilities: runtime.capabilities || [],
      tools: runtime.tools || [],
      concurrency_limit: runtime.concurrency_limit || 1,
      active_assignments: runtime.active_assignments || 0,
      created_at: runtime.created_at,
      heartbeat_at: runtime.heartbeat_at,
      expired_at: runtime.expired_at,
      cleaned_at: runtime.cleaned_at,
      failure_reason: runtime.failure_reason,
      metadata: runtime.metadata || %{}
    }
  end

  defp event_attrs(%LifecycleEvent{} = event) do
    %{
      id: event.id,
      runtime_id: event.runtime_id,
      workspace_id: event.workspace_id,
      event: event.event,
      from_status: event.from_status,
      to_status: event.to_status,
      actor_id: event.actor_id,
      assignment_id: event.assignment_id,
      runner_id: event.runner_id,
      metadata: event.metadata || %{},
      inserted_at: event.inserted_at
    }
  end

  defp to_runtime(%RuntimeRow{} = row) do
    %Runtime{
      id: row.id,
      workspace_id: row.workspace_id,
      host_id: row.host_id,
      os: row.os,
      repo: row.repo,
      branch: row.branch,
      worktree_path: row.worktree_path,
      runner_id: row.runner_id,
      session_id: row.session_id,
      tmux_session_id: row.tmux_session_id,
      isolation_mode: row.isolation_mode,
      status: row.status,
      capabilities: row.capabilities || [],
      tools: row.tools || [],
      concurrency_limit: row.concurrency_limit || 1,
      active_assignments: row.active_assignments || 0,
      created_at: row.created_at,
      heartbeat_at: row.heartbeat_at,
      expired_at: row.expired_at,
      cleaned_at: row.cleaned_at,
      failure_reason: row.failure_reason,
      metadata: row.metadata || %{},
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  defp to_event(%LifecycleEventRow{} = row) do
    %LifecycleEvent{
      id: row.id,
      runtime_id: row.runtime_id,
      workspace_id: row.workspace_id,
      event: row.event,
      from_status: row.from_status,
      to_status: row.to_status,
      actor_id: row.actor_id,
      assignment_id: row.assignment_id,
      runner_id: row.runner_id,
      metadata: row.metadata || %{},
      inserted_at: row.inserted_at
    }
  end
end
