defmodule Casein.Codex.Store.EctoAdapter do
  @moduledoc "Postgres-backed canonical Codex event and projection store."

  @behaviour Casein.Codex.Store.Adapter

  import Ecto.Query

  alias Casein.Codex.Event
  alias Casein.Codex.Store.{ApprovalRow, EventRow, Projection, ThreadRow}
  alias Casein.Repo

  @impl true
  def record(%Event{} = event) do
    Repo.transaction(fn ->
      insert_event!(event)
      project_thread!(event)
      project_approval!(event)
    end)
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def latest_sequence(runtime_id) do
    EventRow
    |> where([event], event.runtime_id == ^runtime_id)
    |> select([event], max(event.sequence))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @impl true
  def workspace_snapshot(workspace_id, opts) do
    limit = opts |> Keyword.get(:limit, 100) |> clamp_limit()

    threads =
      ThreadRow
      |> where([thread], thread.workspace_id == ^workspace_id)
      |> order_by([thread], desc: thread.last_event_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&thread_map/1)

    approval_query =
      ApprovalRow
      |> where([approval], approval.workspace_id == ^workspace_id)
      |> maybe_pending_only(Keyword.get(opts, :pending_only, false))
      |> order_by([approval], desc: approval.requested_at)
      |> limit(^limit)

    %{threads: threads, approvals: Enum.map(Repo.all(approval_query), &approval_map/1)}
  end

  @impl true
  def timeline(workspace_id, thread_id, opts) do
    limit = opts |> Keyword.get(:limit, 200) |> clamp_limit()

    EventRow
    |> where([event], event.workspace_id == ^workspace_id and event.thread_id == ^thread_id)
    |> order_by([event], desc: event.occurred_at, desc: event.sequence)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&to_event/1)
  end

  @impl true
  def clear do
    Repo.delete_all(ApprovalRow)
    Repo.delete_all(ThreadRow)
    Repo.delete_all(EventRow)
    :ok
  end

  defp insert_event!(event) do
    %EventRow{}
    |> Ecto.Changeset.change(event_attrs(event))
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:id])
  end

  defp project_thread!(%Event{thread_id: thread_id} = event)
       when is_binary(thread_id) and thread_id != "" do
    existing = Repo.get(ThreadRow, thread_id)
    projected = Projection.thread(existing && thread_map(existing), event)

    changes = thread_attrs(projected)

    case existing do
      nil -> %ThreadRow{} |> Ecto.Changeset.change(changes) |> Repo.insert!()
      row -> row |> Ecto.Changeset.change(changes) |> Repo.update!()
    end
  end

  defp project_thread!(_event), do: :ok

  defp project_approval!(event) do
    approval_id = payload_value(event.payload, :approval_id)

    if is_binary(approval_id) and event.type in [:approval_requested, :approval_resolved] do
      existing = Repo.get(ApprovalRow, approval_id)
      projected = Projection.approval(existing && approval_map(existing), event)
      changes = approval_attrs(projected)

      case existing do
        nil -> %ApprovalRow{} |> Ecto.Changeset.change(changes) |> Repo.insert!()
        row -> row |> Ecto.Changeset.change(changes) |> Repo.update!()
      end
    else
      :ok
    end
  end

  defp event_attrs(event) do
    %{
      id: event.id,
      workspace_id: event.workspace_id,
      runtime_id: event.runtime_id,
      transport: Atom.to_string(event.transport),
      event_type: Atom.to_string(event.type),
      sequence: event.sequence,
      occurred_at: to_usec(event.occurred_at),
      thread_id: event.thread_id,
      parent_thread_id: event.parent_thread_id,
      session_id: event.session_id,
      turn_id: event.turn_id,
      item_id: event.item_id,
      tool_call_id: event.tool_call_id,
      request_id: event.request_id && to_string(event.request_id),
      payload: json_map(event.payload),
      metadata: json_map(event.metadata)
    }
  end

  defp thread_attrs(thread) do
    thread
    |> Map.take([
      :thread_id,
      :workspace_id,
      :runtime_id,
      :parent_thread_id,
      :session_id,
      :status,
      :current_turn_id,
      :agent_role,
      :agent_nickname,
      :preview,
      :last_sequence,
      :last_event_at
    ])
    |> Map.update!(:last_event_at, &to_usec/1)
    |> Map.put(:transport, to_string(thread.transport))
    |> Map.put(:active_flags, %{"values" => thread.active_flags || []})
    |> Map.put(:usage, json_map(thread.usage || %{}))
    |> Map.put(:metadata, json_map(thread.metadata || %{}))
  end

  defp approval_attrs(approval) do
    approval
    |> Map.take([
      :id,
      :workspace_id,
      :runtime_id,
      :thread_id,
      :turn_id,
      :item_id,
      :request_id,
      :kind,
      :status,
      :requested_at,
      :resolved_at
    ])
    |> Map.update!(:requested_at, &to_usec/1)
    |> Map.update(:resolved_at, nil, &to_usec/1)
    |> Map.put(:resolution, json_map(approval.resolution || %{}))
    |> Map.put(:payload, json_map(approval.payload || %{}))
    |> Map.put(:metadata, json_map(approval.metadata || %{}))
  end

  defp thread_map(%ThreadRow{} = row) do
    %{
      thread_id: row.thread_id,
      workspace_id: row.workspace_id,
      runtime_id: row.runtime_id,
      parent_thread_id: row.parent_thread_id,
      session_id: row.session_id,
      transport: safe_atom(row.transport, :app_server),
      status: row.status,
      active_flags: Map.get(row.active_flags || %{}, "values", []),
      current_turn_id: row.current_turn_id,
      agent_role: row.agent_role,
      agent_nickname: row.agent_nickname,
      preview: row.preview,
      usage: row.usage || %{},
      last_sequence: row.last_sequence,
      last_event_at: row.last_event_at,
      metadata: row.metadata || %{}
    }
  end

  defp approval_map(%ApprovalRow{} = row) do
    %{
      id: row.id,
      workspace_id: row.workspace_id,
      runtime_id: row.runtime_id,
      thread_id: row.thread_id,
      turn_id: row.turn_id,
      item_id: row.item_id,
      request_id: row.request_id,
      kind: row.kind,
      status: row.status,
      resolution: row.resolution || %{},
      payload: row.payload || %{},
      metadata: row.metadata || %{},
      requested_at: row.requested_at,
      resolved_at: row.resolved_at
    }
  end

  defp to_event(%EventRow{} = row) do
    %Event{
      id: row.id,
      type: safe_atom(row.event_type, :error),
      workspace_id: row.workspace_id,
      runtime_id: row.runtime_id,
      transport: safe_atom(row.transport, :app_server),
      sequence: row.sequence,
      occurred_at: row.occurred_at,
      thread_id: row.thread_id,
      parent_thread_id: row.parent_thread_id,
      session_id: row.session_id,
      turn_id: row.turn_id,
      item_id: row.item_id,
      tool_call_id: row.tool_call_id,
      request_id: row.request_id,
      payload: row.payload || %{},
      metadata: row.metadata || %{}
    }
  end

  defp maybe_pending_only(query, true), do: where(query, [approval], approval.status == "pending")
  defp maybe_pending_only(query, _false), do: query
  defp payload_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp clamp_limit(value) when is_integer(value), do: value |> max(1) |> min(1_000)
  defp clamp_limit(_value), do: 100

  defp json_map(map) when is_map(map) do
    map
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp json_map(_value), do: %{}

  defp safe_atom(value, fallback) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> fallback
  end

  defp to_usec(nil), do: nil

  defp to_usec(%DateTime{microsecond: {usec, _precision}} = datetime),
    do: %{datetime | microsecond: {usec, 6}}
end
