defmodule DevIDE.PreviewActivity do
  @moduledoc """
  Recent per-preview-pane activity feed.

  This is intentionally short-lived and bounded. Durable audit remains in
  `DevIDE.Audit` and `DevIDE.Previews.ControlAction`; this feed answers the
  operator/agent question "what just happened in this preview pane?"
  """

  use GenServer

  alias Phoenix.PubSub

  @topic_prefix "preview_activity:"
  @default_limit 20
  @max_per_workspace 300

  @type entry :: %{
          id: String.t(),
          workspace_id: String.t() | nil,
          pane_id: String.t() | nil,
          session_id: integer() | nil,
          preview_id: integer() | nil,
          source: :browser | :preview_control | :preview_pane | :mcp,
          event: String.t(),
          summary: String.t(),
          metadata: map(),
          inserted_at: DateTime.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe(String.t()) :: :ok
  def subscribe(workspace_id) when is_binary(workspace_id) do
    PubSub.subscribe(DevIDE.PubSub, topic(workspace_id))
  end

  @spec record(map()) :: entry()
  def record(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:record, attrs})
  end

  @spec recent_workspace(String.t(), pos_integer()) :: [entry()]
  def recent_workspace(workspace_id, limit \\ @default_limit) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:recent_workspace, workspace_id, limit})
  end

  @spec recent_pane(String.t(), String.t(), pos_integer()) :: [entry()]
  def recent_pane(workspace_id, pane_id, limit \\ @default_limit)
      when is_binary(workspace_id) and is_binary(pane_id) do
    GenServer.call(__MODULE__, {:recent_pane, workspace_id, pane_id, limit})
  end

  @spec latest_pane(String.t(), String.t()) :: entry() | nil
  def latest_pane(workspace_id, pane_id) when is_binary(workspace_id) and is_binary(pane_id) do
    case recent_pane(workspace_id, pane_id, 1) do
      [entry] -> entry
      [] -> nil
    end
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:recent_workspace, workspace_id, limit}, _from, state) do
    entries =
      state
      |> Map.get(workspace_id, [])
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  def handle_call({:recent_pane, workspace_id, pane_id, limit}, _from, state) do
    entries =
      state
      |> Map.get(workspace_id, [])
      |> Enum.filter(&(&1.pane_id == pane_id))
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
      PubSub.broadcast(DevIDE.PubSub, topic(workspace_id), {:preview_activity, entry})
    end

    {:reply, entry, updated}
  end

  defp build_entry(attrs) do
    %{
      id: Map.get(attrs, :id, Ecto.UUID.generate()),
      workspace_id: optional_string(Map.get(attrs, :workspace_id)),
      pane_id: optional_string(Map.get(attrs, :pane_id)),
      session_id: optional_integer(Map.get(attrs, :session_id)),
      preview_id: optional_integer(Map.get(attrs, :preview_id)),
      source: Map.get(attrs, :source, :browser),
      event: attrs |> Map.get(:event, "preview") |> to_string(),
      summary: attrs |> Map.get(:summary, "") |> to_string(),
      metadata: Map.get(attrs, :metadata, %{}) || %{},
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

  defp optional_integer(value) when is_integer(value), do: value

  defp optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp optional_integer(_), do: nil

  defp topic(workspace_id), do: @topic_prefix <> workspace_id
end
