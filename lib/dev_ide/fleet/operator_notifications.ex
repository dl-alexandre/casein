defmodule DevIDE.Fleet.OperatorNotifications do
  @moduledoc """
  Best-effort operator notification hooks for fleet workflows.

  Notifications are intentionally non-authoritative. They are emitted only
  after the owning command/event mutation has returned, and losing one does not
  affect assignment, execution, recovery, or dossier state.
  """

  use GenServer

  @max 500

  @type kind :: :completed | :failed | :stale | :recovered

  @type t :: %{
          id: String.t(),
          kind: kind(),
          workspace_id: String.t() | nil,
          assignment_id: String.t() | nil,
          execution_id: String.t() | nil,
          runner_id: String.t() | nil,
          lease_id: String.t() | nil,
          message: String.t(),
          metadata: map(),
          occurred_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec emit(kind(), map()) :: {:ok, t()}
  def emit(kind, attrs)
      when kind in [:completed, :failed, :stale, :recovered] and is_map(attrs) do
    notification = new(kind, attrs)

    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:emit, notification})
    end

    {:ok, notification}
  rescue
    _ -> {:ok, new(kind, attrs)}
  end

  @spec list(keyword()) :: [t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, @max)
    workspace_id = Keyword.get(opts, :workspace_id)

    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, {:list, limit, workspace_id})
    end
  end

  @spec clear() :: :ok
  def clear do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :clear)
    end
  end

  @impl GenServer
  def init([]), do: {:ok, []}

  @impl GenServer
  def handle_cast({:emit, notification}, notifications) do
    {:noreply, [notification | notifications] |> Enum.take(@max)}
  end

  @impl GenServer
  def handle_call({:list, limit, workspace_id}, _from, notifications) do
    filtered =
      notifications
      |> filter_workspace(workspace_id)
      |> Enum.take(limit)

    {:reply, filtered, notifications}
  end

  def handle_call(:clear, _from, _notifications), do: {:reply, :ok, []}

  defp new(kind, attrs) do
    %{
      id: Ecto.UUID.generate(),
      kind: kind,
      workspace_id: value(attrs, :workspace_id),
      assignment_id: value(attrs, :assignment_id),
      execution_id: value(attrs, :execution_id),
      runner_id: value(attrs, :runner_id),
      lease_id: value(attrs, :lease_id),
      message: value(attrs, :message) || default_message(kind),
      metadata: value(attrs, :metadata) || %{},
      occurred_at: value(attrs, :occurred_at) || DateTime.utc_now()
    }
  end

  defp default_message(:completed), do: "Delegated execution completed"
  defp default_message(:failed), do: "Delegated execution failed"
  defp default_message(:stale), do: "Recovery proposal is stale"
  defp default_message(:recovered), do: "Delegated execution recovered"

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp filter_workspace(notifications, nil), do: notifications

  defp filter_workspace(notifications, workspace_id) when is_binary(workspace_id) do
    Enum.filter(notifications, &(&1.workspace_id == workspace_id))
  end
end
