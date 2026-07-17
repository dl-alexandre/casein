defmodule DevIDE.Codex.Runtime do
  @moduledoc """
  Supervision boundary for one Codex home/worktree/security context.

  Threads, turns, and items remain data. The runtime supervises only the
  long-lived EventRouter, ApprovalBroker, and AppServer processes.
  """

  use Supervisor

  alias DevIDE.Codex.{AppServer, ApprovalBroker, EventRouter}

  @registry DevIDE.Codex.Registry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    runtime_id = Keyword.fetch!(opts, :runtime_id)
    name = Keyword.get(opts, :name, component_via(runtime_id, :runtime))
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    runtime_id = Keyword.fetch!(opts, :runtime_id)

    %{
      id: {__MODULE__, runtime_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    runtime_id = Keyword.fetch!(opts, :runtime_id)
    event_router = component_via(runtime_id, :event_router)
    approval_broker = component_via(runtime_id, :approval_broker)

    app_server_opts =
      opts
      |> Keyword.drop([:name, :subscriber])
      |> Keyword.put(:name, component_via(runtime_id, :app_server))
      |> Keyword.put(:event_router, event_router)
      |> Keyword.put(:approval_broker, approval_broker)

    children = [
      {EventRouter,
       workspace_id: workspace_id,
       runtime_id: runtime_id,
       subscriber: Keyword.get(opts, :subscriber),
       name: event_router},
      {ApprovalBroker,
       workspace_id: workspace_id,
       runtime_id: runtime_id,
       event_router: event_router,
       name: approval_broker},
      {AppServer, app_server_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec await_ready(String.t(), timeout()) :: :ok | {:error, term()}
  def await_ready(runtime_id, timeout \\ 10_000) do
    AppServer.await_ready(app_server(runtime_id), timeout)
  end

  @spec subscribe(String.t(), pid()) :: :ok
  def subscribe(runtime_id, subscriber \\ self()) do
    EventRouter.subscribe(event_router(runtime_id), subscriber)
  end

  @spec start_thread(String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def start_thread(runtime_id, params \\ %{}, timeout \\ 30_000) do
    AppServer.start_thread(app_server(runtime_id), params, timeout)
  end

  @spec resume_thread(String.t(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def resume_thread(runtime_id, thread_id, params \\ %{}, timeout \\ 30_000) do
    AppServer.resume_thread(app_server(runtime_id), thread_id, params, timeout)
  end

  @spec start_turn(String.t(), String.t(), String.t() | [map()], map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def start_turn(runtime_id, thread_id, input, params \\ %{}, timeout \\ 30_000) do
    AppServer.start_turn(app_server(runtime_id), thread_id, input, params, timeout)
  end

  @spec resolve_approval(String.t(), String.t(), ApprovalBroker.decision()) ::
          {:ok, DevIDE.Codex.Approval.t()} | {:error, term()}
  def resolve_approval(runtime_id, approval_id, decision) do
    ApprovalBroker.resolve(approval_broker(runtime_id), approval_id, decision)
  end

  @spec pending_approvals(String.t()) :: [DevIDE.Codex.Approval.t()]
  def pending_approvals(runtime_id), do: ApprovalBroker.pending(approval_broker(runtime_id))

  @spec snapshot(String.t()) :: map()
  def snapshot(runtime_id), do: EventRouter.snapshot(event_router(runtime_id))

  @spec app_server(String.t()) :: GenServer.server()
  def app_server(runtime_id), do: component_via(runtime_id, :app_server)

  @spec approval_broker(String.t()) :: GenServer.server()
  def approval_broker(runtime_id), do: component_via(runtime_id, :approval_broker)

  @spec event_router(String.t()) :: GenServer.server()
  def event_router(runtime_id), do: component_via(runtime_id, :event_router)

  @spec whereis_component(String.t(), atom()) :: pid() | nil
  def whereis_component(runtime_id, component) do
    case Registry.lookup(@registry, {component, runtime_id}) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @spec component_via(String.t(), atom()) :: {:via, Registry, {module(), term()}}
  def component_via(runtime_id, component),
    do: {:via, Registry, {@registry, {component, runtime_id}}}
end
