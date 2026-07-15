defmodule DevIDE.Agents.Activity do
  @moduledoc """
  Recent MCP tool-call feed for human operators watching external agents.

  Terminal and preview MCP handlers record invocations here; workspace
  LiveViews subscribe and render the tail in the Agents tab.
  """

  use GenServer

  alias Phoenix.PubSub

  @topic_prefix "agent_activity:"
  @default_limit 30
  @max_per_workspace 200

  @type entry :: %{
          id: String.t(),
          workspace_id: String.t() | nil,
          source: :terminal_mcp | :preview_mcp | :artifact_mcp,
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
      state
      |> Map.get(workspace_id, [])
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  def handle_call({:record, attrs}, _from, state) do
    entry = build_entry(attrs)
    workspace_id = entry.workspace_id

    updated =
      if is_binary(workspace_id) do
        list = [entry | Map.get(state, workspace_id, [])] |> Enum.take(@max_per_workspace)
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

  defp topic(workspace_id), do: @topic_prefix <> workspace_id
end
