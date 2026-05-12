defmodule DevIDE.Fleet.Queue do
  @moduledoc """
  Pending-assignment queue for the fleet placement engine.

  Assignments enter the queue with their `AssignmentRequirements`.
  The queue is ordered by priority (high → normal → low) and then
  by enqueue time (FIFO within each priority band).

  ## Placement pass

  A placement pass (typically triggered by `Fleet.PlacementPass`)
  dequeues the next pending assignment, attempts to place it, and
  either acquires a lease or re-queues the assignment at the back
  of its priority band.

  All state is ephemeral.  If the queue process restarts, pending
  assignments are rebuilt from the durable assignment event store.
  """

  use GenServer

  alias DevIDE.Fleet.AssignmentRequirements

  @type entry :: %{
          assignment_id: String.t(),
          requirements: AssignmentRequirements.t(),
          enqueued_at: DateTime.t()
        }

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add an assignment to the queue with its placement requirements."
  @spec enqueue(String.t(), AssignmentRequirements.t()) :: :ok
  def enqueue(assignment_id, %AssignmentRequirements{} = requirements) do
    GenServer.call(__MODULE__, {:enqueue, assignment_id, requirements})
  end

  @doc "Remove an assignment from the queue."
  @spec remove(String.t()) :: :ok
  def remove(assignment_id) do
    GenServer.call(__MODULE__, {:remove, assignment_id})
  end

  @doc "Peek at the next assignment without removing it."
  @spec peek() :: entry() | nil
  def peek, do: GenServer.call(__MODULE__, :peek)

  @doc "Dequeue the next entry. Returns `nil` if queue is empty."
  @spec dequeue() :: entry() | nil
  def dequeue, do: GenServer.call(__MODULE__, :dequeue)

  @doc "Return all entries ordered by priority then enqueue time."
  @spec list() :: [entry()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Return only entries matching a given priority."
  @spec list_by_priority(AssignmentRequirements.priority()) :: [entry()]
  def list_by_priority(priority) do
    GenServer.call(__MODULE__, {:list_by_priority, priority})
  end

  @doc "Count of pending assignments."
  @spec count() :: non_neg_integer()
  def count, do: GenServer.call(__MODULE__, :count)

  @doc "Is the given assignment currently queued?"
  @spec queued?(String.t()) :: boolean()
  def queued?(assignment_id), do: GenServer.call(__MODULE__, {:queued?, assignment_id})

  @doc "Clear the queue."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_opts) do
    {:ok, %{queue: [], index: %{}}}
  end

  @impl GenServer
  def handle_call({:enqueue, assignment_id, requirements}, _from, state) do
    if Map.has_key?(state.index, assignment_id) do
      {:reply, :ok, state}
    else
      entry = %{
        assignment_id: assignment_id,
        requirements: requirements,
        enqueued_at: DateTime.utc_now()
      }

      queue = insert_by_priority(state.queue, entry)
      index = Map.put(state.index, assignment_id, entry)

      {:reply, :ok, %{state | queue: queue, index: index}}
    end
  end

  def handle_call({:remove, assignment_id}, _from, state) do
    if Map.has_key?(state.index, assignment_id) do
      queue = Enum.reject(state.queue, &(&1.assignment_id == assignment_id))
      index = Map.delete(state.index, assignment_id)
      {:reply, :ok, %{state | queue: queue, index: index}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:peek, _from, %{queue: []} = state), do: {:reply, nil, state}

  def handle_call(:peek, _from, %{queue: [head | _]} = state),
    do: {:reply, head, state}

  def handle_call(:dequeue, _from, %{queue: []} = state), do: {:reply, nil, state}

  def handle_call(:dequeue, _from, %{queue: [head | rest]} = state) do
    index = Map.delete(state.index, head.assignment_id)
    {:reply, head, %{state | queue: rest, index: index}}
  end

  def handle_call(:list, _from, state) do
    {:reply, state.queue, state}
  end

  def handle_call({:list_by_priority, priority}, _from, state) do
    results = Enum.filter(state.queue, &(&1.requirements.priority == priority))
    {:reply, results, state}
  end

  def handle_call(:count, _from, state) do
    {:reply, length(state.queue), state}
  end

  def handle_call({:queued?, assignment_id}, _from, state) do
    {:reply, Map.has_key?(state.index, assignment_id), state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{queue: [], index: %{}}}
  end

  ## Internal

  defp insert_by_priority(queue, entry) do
    priority_order = %{high: 0, normal: 1, low: 2}
    new_priority = Map.fetch!(priority_order, entry.requirements.priority)

    # Find insertion point: after all higher/equal priority, before lower
    {before, after_entries} =
      Enum.split_while(queue, fn existing ->
        existing_priority = Map.fetch!(priority_order, existing.requirements.priority)
        existing_priority <= new_priority
      end)

    before ++ [entry | after_entries]
  end
end
