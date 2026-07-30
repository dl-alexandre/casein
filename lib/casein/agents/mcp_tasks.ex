defmodule Casein.Agents.MCPTasks do
  @moduledoc """
  Task registry for the MCP Tasks extension (`io.modelcontextprotocol/tasks`).

  Some Casein tools exist *because* blocking does not work: a pane wait can
  outlast any HTTP request, so `terminal_wait_agent_state` caps itself at 55s and
  documents "re-issue the call to keep long-polling". The Tasks extension
  replaces that loop with a durable handle — the server returns a `taskId`, the
  work continues in the background, and the client polls `tasks/get`.

  This GenServer owns:

    * an ETS table of `task_id -> record` (status, timestamps, terminal
      result/error, owner, worker pid), and
    * a monitor on each worker process, so a worker that dies without reporting
      moves its task to `failed` instead of stranding it at `working`.

  It is deliberately the same shape as `Casein.Agents.MCPSessions` — ETS table,
  process monitors, periodic `Process.send_after` sweep — because that module
  solved the same expiry problem for the session registry the 2026-07-28
  revision has now removed.

  ## Ownership

  Every task is stamped with the identity that created it (server, workspace,
  token actor, agent-capability id). `tasks/get`, `tasks/update`, and
  `tasks/cancel` require an exact match and otherwise report `:unknown_task` —
  never "forbidden", so a caller cannot probe for the existence of another
  agent's tasks.

  Two callers sharing one bearer token *and* one workspace share an owner. That
  is the same trust boundary they already have: they share the credential.

  ## Cancellation

  `cancel/2` moves a non-terminal task straight to `cancelled` and terminates its
  worker. Terminal states are immutable, so a later `complete/2` from a worker
  that was already mid-flight is dropped.

  This makes abandonment a **precondition for task-eligibility**: a tool may only
  be listed in a handler's `task_tools/0` if killing it partway through is safe.
  That holds for waits and other read-only work; a mutating tool would need
  cooperative checks against `cancelled?/1` instead.

  ## Durability

  "Durable" here means *created before the response is sent* (as the extension
  requires), not surviving a VM restart — the table is ETS. A Casein restart
  already drops in-flight long polls and MCP sessions, so this is no worse than
  the behaviour it replaces.

  Tunables (application env, with inline defaults):

    * `:mcp_task_ttl_ms` — task lifetime from creation (default 30m).
    * `:mcp_task_sweep_interval_ms` — sweep cadence (default 5m).
    * `:mcp_task_poll_interval_ms` — `pollIntervalMs` hint (default 2s).
  """

  use GenServer

  @table __MODULE__
  @task_supervisor Casein.Agents.MCPTaskSupervisor
  @id_bytes 16
  @default_ttl_ms 1_800_000
  @default_sweep_interval_ms 300_000
  @default_poll_interval_ms 2_000

  @terminal_statuses [:completed, :failed, :cancelled]

  @type task_id :: String.t()
  @type owner :: map()
  @type status :: :working | :input_required | :completed | :failed | :cancelled

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a task and run `fun` for it in the background.

  `fun` receives the new task id (so the work can check `cancelled?/1`) and
  returns `{:ok, result}` for a result the original request would have returned
  synchronously, or `{:error, error}` for a JSON-RPC error. The task is written to
  the table before this returns, so the caller may safely answer with its id.
  """
  @spec run(owner(), (task_id() -> {:ok, map()} | {:error, map()}), keyword()) :: {:ok, task_id()}
  def run(owner, fun, opts \\ []) when is_map(owner) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:run, owner, fun, opts})
  end

  @doc "Fetch a task's raw record, ignoring ownership."
  @spec fetch(task_id() | nil) :: {:ok, map()} | :error
  def fetch(task_id) when is_binary(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, record}] -> {:ok, record}
      _ -> :error
    end
  end

  def fetch(_), do: :error

  @doc """
  Fetch a task as a wire-shaped `DetailedTask` for `owner`.

  Returns `{:error, :unknown_task}` for both a missing task and one owned by
  somebody else.
  """
  @spec get(task_id() | nil, owner()) :: {:ok, map()} | {:error, :unknown_task}
  def get(task_id, owner) do
    with {:ok, record} <- fetch(task_id),
         true <- record.owner == owner do
      {:ok, to_wire(record)}
    else
      _ -> {:error, :unknown_task}
    end
  end

  @doc "Whether cancellation has been requested for a task."
  @spec cancelled?(task_id()) :: boolean()
  def cancelled?(task_id) do
    case fetch(task_id) do
      {:ok, record} -> record.status == :cancelled
      :error -> false
    end
  end

  @doc "Cancel a task owned by `owner`, terminating its worker."
  @spec cancel(task_id() | nil, owner()) :: :ok | {:error, :unknown_task}
  def cancel(task_id, owner) do
    GenServer.call(__MODULE__, {:cancel, task_id, owner})
  end

  @doc """
  Record client responses to a task's outstanding input requests.

  Unknown or already-satisfied keys are ignored, so a retry is idempotent.
  """
  @spec update(task_id() | nil, owner(), map()) :: :ok | {:error, :unknown_task}
  def update(task_id, owner, input_responses) when is_map(input_responses) do
    GenServer.call(__MODULE__, {:update, task_id, owner, input_responses})
  end

  @doc "Mark a task completed with the result its request would have returned."
  @spec complete(task_id(), map()) :: :ok
  def complete(task_id, result),
    do: GenServer.call(__MODULE__, {:finish, task_id, :completed, result})

  @doc "Mark a task failed with a JSON-RPC error."
  @spec fail(task_id(), map()) :: :ok
  def fail(task_id, error), do: GenServer.call(__MODULE__, {:finish, task_id, :failed, error})

  @doc "Run the task sweep synchronously; returns the number reaped."
  @spec sweep_now() :: non_neg_integer()
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now)

  @doc "The `pollIntervalMs` hint advertised to clients."
  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms,
    do: Application.get_env(:casein, :mcp_task_poll_interval_ms, @default_poll_interval_ms)

  @doc "The task lifetime advertised as `ttlMs`."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: Application.get_env(:casein, :mcp_task_ttl_ms, @default_ttl_ms)

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    schedule_sweep()
    # monitors: ref => {task_id, pid}
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:run, owner, fun, opts}, _from, state) do
    task_id = generate_id()
    now = DateTime.utc_now()

    record = %{
      task_id: task_id,
      status: :working,
      status_message: Keyword.get(opts, :status_message),
      created_at: now,
      last_updated_at: now,
      created_at_ms: now_ms(),
      ttl_ms: Keyword.get(opts, :ttl_ms, ttl_ms()),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, poll_interval_ms()),
      result: nil,
      error: nil,
      input_requests: %{},
      input_responses: %{},
      owner: owner,
      worker: nil
    }

    # Written before the worker starts, so the id we return is always resolvable.
    :ets.insert(@table, {task_id, record})

    state =
      case Task.Supervisor.start_child(@task_supervisor, fn -> work(task_id, fun) end) do
        {:ok, pid} ->
          :ets.insert(@table, {task_id, %{record | worker: pid}})
          ref = Process.monitor(pid)
          put_in(state, [:monitors, ref], {task_id, pid})

        {:error, reason} ->
          finish(task_id, :failed, %{
            code: -32_603,
            message: "Could not start task worker",
            data: %{reason: inspect(reason)}
          })

          state
      end

    {:reply, {:ok, task_id}, state}
  end

  def handle_call({:finish, task_id, status, payload}, _from, state) do
    finish(task_id, status, payload)
    {:reply, :ok, state}
  end

  def handle_call({:cancel, task_id, owner}, _from, state) do
    case owned(task_id, owner) do
      {:ok, record} ->
        state =
          if record.status in @terminal_statuses do
            state
          else
            # Terminal from here: a late complete/2 from the worker is dropped.
            put_record(%{record | status: :cancelled, last_updated_at: DateTime.utc_now()})
            stop_worker(state, record)
          end

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_task}, state}
    end
  end

  def handle_call({:update, task_id, owner, input_responses}, _from, state) do
    case owned(task_id, owner) do
      {:ok, record} ->
        # Only keys that are currently outstanding are accepted, which makes a
        # duplicate submission a no-op rather than an error.
        accepted = Map.take(input_responses, Map.keys(record.input_requests))

        if accepted == %{} do
          {:reply, :ok, state}
        else
          outstanding = Map.drop(record.input_requests, Map.keys(accepted))

          put_record(%{
            record
            | input_requests: outstanding,
              input_responses: Map.merge(record.input_responses, accepted),
              status: if(outstanding == %{}, do: :working, else: :input_required),
              last_updated_at: DateTime.utc_now()
          })

          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :unknown_task}, state}
    end
  end

  def handle_call(:sweep_now, _from, state) do
    {count, state} = do_sweep(state)
    {:reply, count, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    {_count, state} = do_sweep(state)
    schedule_sweep()
    {:noreply, state}
  end

  # A worker that exited without reporting leaves its task at `working` forever;
  # surface that as `failed` rather than waiting out the TTL.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{task_id, ^pid}, monitors} ->
        if reason != :normal do
          maybe_fail_stranded(task_id, reason)
        end

        {:noreply, %{state | monitors: monitors}}

      {_other, _monitors} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal ---

  defp work(task_id, fun) do
    case fun.(task_id) do
      {:ok, result} when is_map(result) ->
        complete(task_id, result)

      {:error, error} when is_map(error) ->
        fail(task_id, error)

      other ->
        fail(task_id, %{
          code: -32_603,
          message: "Task worker returned an unexpected shape",
          data: %{returned: inspect(other)}
        })
    end
  end

  defp finish(task_id, status, payload) do
    case fetch(task_id) do
      # Terminal states are immutable — a cancelled task stays cancelled even if
      # its worker later reports a result.
      {:ok, %{status: current}} when current in @terminal_statuses ->
        :ok

      {:ok, record} ->
        key = if status == :completed, do: :result, else: :error

        put_record(
          record
          |> Map.put(:status, status)
          |> Map.put(key, payload)
          |> Map.put(:last_updated_at, DateTime.utc_now())
        )

      :error ->
        :ok
    end
  end

  defp maybe_fail_stranded(task_id, reason) do
    finish(task_id, :failed, %{
      code: -32_603,
      message: "Task worker exited before reporting a result",
      data: %{reason: inspect(reason)}
    })
  end

  defp owned(task_id, owner) do
    case fetch(task_id) do
      {:ok, record} -> if record.owner == owner, do: {:ok, record}, else: :error
      :error -> :error
    end
  end

  @doc """
  Subscribe the caller to a task's status changes.

  Feeds `notifications/tasks` on a `subscriptions/listen` stream, so a client can
  stop polling `tasks/get`.
  """
  @spec subscribe(task_id()) :: :ok | {:error, term()}
  def subscribe(task_id) when is_binary(task_id) do
    Phoenix.PubSub.subscribe(Casein.PubSub, topic(task_id))
  end

  @doc "PubSub topic carrying one task's status changes."
  @spec topic(task_id()) :: String.t()
  def topic(task_id), do: "mcp_tasks:" <> task_id

  defp put_record(record) do
    :ets.insert(@table, {record.task_id, record})
    Phoenix.PubSub.broadcast(Casein.PubSub, topic(record.task_id), {:mcp_task, to_wire(record)})
    true
  end

  defp stop_worker(state, %{worker: pid} = record) when is_pid(pid) do
    _ = Task.Supervisor.terminate_child(@task_supervisor, pid)
    demonitor_task(state, record.task_id)
  end

  defp stop_worker(state, _record), do: state

  defp demonitor_task(state, task_id) do
    {refs, monitors} =
      Enum.reduce(state.monitors, {[], state.monitors}, fn
        {ref, {^task_id, _pid}}, {refs, acc} -> {[ref | refs], Map.delete(acc, ref)}
        {_ref, _val}, {refs, acc} -> {refs, acc}
      end)

    Enum.each(refs, &Process.demonitor(&1, [:flush]))
    %{state | monitors: monitors}
  end

  @doc """
  Render a record as the extension's wire shape.

  `Task` fields are flat; the status-specific field (`result`, `error`,
  `inputRequests`) is inlined per `DetailedTask`.
  """
  @spec to_wire(map()) :: map()
  def to_wire(record) do
    %{
      taskId: record.task_id,
      status: Atom.to_string(record.status),
      createdAt: DateTime.to_iso8601(record.created_at),
      lastUpdatedAt: DateTime.to_iso8601(record.last_updated_at),
      ttlMs: record.ttl_ms,
      pollIntervalMs: record.poll_interval_ms
    }
    |> maybe_put(:statusMessage, record.status_message)
    |> put_status_payload(record)
  end

  defp put_status_payload(wire, %{status: :completed, result: result}),
    do: Map.put(wire, :result, result || %{})

  defp put_status_payload(wire, %{status: :failed, error: error}),
    do: Map.put(wire, :error, error || %{})

  defp put_status_payload(wire, %{status: :input_required, input_requests: requests}),
    do: Map.put(wire, :inputRequests, requests)

  defp put_status_payload(wire, _record), do: wire

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generate_id do
    @id_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  # Reap tasks past their TTL, except ones still being worked — mirroring the
  # session sweep's "except ones with a live attached stream".
  defp do_sweep(state) do
    now = now_ms()

    reapable =
      :ets.foldl(
        fn {task_id, record}, acc ->
          if reapable?(record, now), do: [task_id | acc], else: acc
        end,
        [],
        @table
      )

    state =
      Enum.reduce(reapable, state, fn task_id, st ->
        st = demonitor_task(st, task_id)
        :ets.delete(@table, task_id)
        st
      end)

    {length(reapable), state}
  end

  defp reapable?(record, now) do
    expired? = is_integer(record.ttl_ms) and now - record.created_at_ms >= record.ttl_ms
    expired? and (record.status in @terminal_statuses or not live_worker?(record.worker))
  end

  defp live_worker?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp live_worker?(_), do: false

  defp sweep_interval_ms,
    do: Application.get_env(:casein, :mcp_task_sweep_interval_ms, @default_sweep_interval_ms)
end
