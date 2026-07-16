defmodule DevIDE.Agents.Activity do
  @moduledoc """
  Recent agent activity feed for human operators watching external agents.

  Terminal/preview MCP handlers and structured runtime adapters record events
  here; workspace LiveViews subscribe and render the tail.
  """

  use GenServer

  alias DevIDE.Agents.{AgentEvent, AgentEvents}
  alias Phoenix.PubSub

  @topic_prefix "agent_activity:"
  @default_limit 30
  @max_per_workspace 200

  @type entry :: %{
          id: String.t(),
          workspace_id: String.t() | nil,
          source:
            :terminal_mcp
            | :preview_mcp
            | :artifact_mcp
            | :grok_acp
            | :agent_state
            | :transcript
            | :worktree
            | :agent_event,
          tool: String.t(),
          summary: String.t(),
          metadata: map(),
          status: :ok | :error,
          inserted_at: DateTime.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe(String.t()) :: :ok
  def subscribe(workspace_id) when is_binary(workspace_id) do
    PubSub.subscribe(DevIDE.PubSub, topic(workspace_id))
  end

  @spec recent(String.t(), pos_integer()) :: [entry()]
  def recent(workspace_id, limit \\ @default_limit) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:recent, workspace_id, limit})
  end

  @spec record(map()) :: entry()
  def record(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:record, attrs})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:recent, workspace_id, limit}, _from, state) do
    entries =
      (Map.get(state, workspace_id, []) ++ persisted_entries(workspace_id, limit))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  def handle_call(:clear, _from, _state) do
    if Application.get_env(:dev_ide, :agent_events_adapter) ==
         DevIDE.Agents.AgentEvents.MemoryAdapter do
      _ = AgentEvents.clear()
    end

    {:reply, :ok, %{}}
  end

  def handle_call({:record, attrs}, _from, state) do
    entry = build_entry(attrs)
    workspace_id = entry.workspace_id

    updated =
      if is_binary(workspace_id) do
        list =
          [entry | Map.get(state, workspace_id, [])]
          |> Enum.uniq_by(& &1.id)
          |> Enum.take(@max_per_workspace)

        Map.put(state, workspace_id, list)
      else
        state
      end

    if is_binary(workspace_id) do
      PubSub.broadcast(DevIDE.PubSub, topic(workspace_id), {:agent_mcp_activity, entry})
    end

    {:reply, entry, updated}
  end

  defp build_entry(attrs) do
    %{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      workspace_id: optional_string(Map.get(attrs, :workspace_id)),
      source: Map.get(attrs, :source, :terminal_mcp),
      tool: Map.fetch!(attrs, :tool),
      summary: Map.get(attrs, :summary, ""),
      metadata: Map.get(attrs, :metadata, %{}),
      status: Map.get(attrs, :status, :ok),
      inserted_at: Map.get(attrs, :inserted_at, DateTime.utc_now())
    }
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp optional_string(_), do: nil

  defp persisted_entries(workspace_id, limit) do
    workspace_id
    |> AgentEvents.recent_for(limit: limit)
    |> Enum.map(&event_entry/1)
  rescue
    _reason -> []
  catch
    :exit, _reason -> []
  end

  defp event_entry(%AgentEvent{} = event) do
    %{
      id: event.id,
      workspace_id: event.workspace_id,
      source: :agent_event,
      tool: Map.get(event.payload || %{}, "tool") || event.event_type,
      summary: event.summary || event.event_type,
      metadata:
        Map.merge(event.payload || %{}, %{
          event_type: event.event_type,
          producer: event.producer,
          ingress: event.ingress,
          agent_session_id: event.agent_session_id,
          tmux_session_id: event.tmux_session_id,
          pane_id: event.pane_id,
          runtime_id: event.runtime_id
        }),
      status: if(event.status in ["error", "failed"], do: :error, else: :ok),
      inserted_at: event.occurred_at
    }
  end

  defp topic(workspace_id), do: @topic_prefix <> workspace_id
end
