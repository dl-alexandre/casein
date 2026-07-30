defmodule Casein.Agents.AgentEvents.EctoAdapter do
  @moduledoc false

  @behaviour Casein.Agents.AgentEvents.Adapter

  import Ecto.Query

  alias Casein.Agents.AgentEvent
  alias Casein.Repo

  @impl true
  def record(attrs) do
    case existing(attrs) do
      %AgentEvent{} = event ->
        {:ok, event, :duplicate}

      nil ->
        insert(attrs)
    end
  end

  @impl true
  def recent_for(workspace_id, opts) do
    AgentEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> newest_first()
    |> limit(^Keyword.fetch!(opts, :limit))
    |> Repo.all()
  end

  @impl true
  def replay(workspace_id, after_at, after_id, opts) do
    AgentEvent
    |> where([event], event.workspace_id == ^workspace_id)
    |> after_cursor(after_at, after_id)
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> limit(^Keyword.fetch!(opts, :limit))
    |> Repo.all()
  end

  @impl true
  def list_for_session(workspace_id, agent_session_id, opts) do
    AgentEvent
    |> where(
      [event],
      event.workspace_id == ^workspace_id and event.agent_session_id == ^agent_session_id
    )
    |> newest_first()
    |> limit(^Keyword.fetch!(opts, :limit))
    |> Repo.all()
  end

  @impl true
  def list_by_event_types(workspace_id, event_types) do
    AgentEvent
    |> where(
      [event],
      event.workspace_id == ^workspace_id and event.event_type in ^event_types
    )
    |> newest_first()
    |> Repo.all()
  end

  @impl true
  def list_open_clarifications(workspace_id, request_type, resolved_type, opts) do
    resolved =
      from(resolution in AgentEvent,
        where:
          resolution.workspace_id == ^workspace_id and
            resolution.event_type == ^resolved_type,
        where:
          fragment(
            "?->>'request_event_id' = (?::text)",
            resolution.payload,
            parent_as(:request).id
          ),
        select: 1
      )

    newest_per_target =
      from(request in AgentEvent,
        where:
          request.workspace_id == ^workspace_id and
            request.event_type == ^request_type,
        distinct: [
          request.agent_session_id,
          request.tmux_session_id,
          request.pane_id
        ],
        order_by: [
          asc: request.agent_session_id,
          asc: request.tmux_session_id,
          asc: request.pane_id,
          desc: request.inserted_at,
          desc: request.id
        ]
      )

    from(request in subquery(newest_per_target),
      as: :request,
      where: not exists(subquery(resolved)),
      order_by: [desc: request.inserted_at, desc: request.id],
      limit: ^Keyword.fetch!(opts, :limit)
    )
    |> Repo.all()
  end

  @impl true
  def list_by_correlation(correlation_id, opts) do
    AgentEvent
    |> where([event], event.correlation_id == ^correlation_id)
    |> order_by([event],
      asc: event.occurred_at,
      asc: event.inserted_at,
      asc: event.id
    )
    |> limit(^Keyword.fetch!(opts, :limit))
    |> Repo.all()
  end

  @impl true
  def clear do
    Repo.delete_all(AgentEvent)
    :ok
  end

  defp insert(attrs) do
    changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

    case Repo.insert(changeset) do
      {:ok, event} ->
        {:ok, event, :inserted}

      {:error, _changeset} = error ->
        case existing(attrs) do
          %AgentEvent{} = event -> {:ok, event, :duplicate}
          nil -> error
        end
    end
  end

  defp existing(%{source_event_id: source_event_id} = attrs)
       when is_binary(source_event_id) and source_event_id != "" do
    Repo.get_by(AgentEvent,
      workspace_id: attrs.workspace_id,
      stream_id: attrs.stream_id,
      source_event_id: source_event_id
    )
  end

  defp existing(_attrs), do: nil

  defp newest_first(query) do
    order_by(query, [event],
      desc: event.occurred_at,
      desc: event.inserted_at,
      desc: event.id
    )
  end

  defp after_cursor(query, %DateTime{} = after_at, after_id) when is_binary(after_id) do
    where(
      query,
      [event],
      event.inserted_at > ^after_at or
        (event.inserted_at == ^after_at and event.id > ^after_id)
    )
  end

  defp after_cursor(query, _after_at, _after_id), do: query
end
