defmodule Casein.Agents.JidoWorkcell.Cell do
  @moduledoc """
  One supervised Workcell per workspace.

  The existing Jido pod remains the bounded worker engine. This cell owns the
  external Workcell identity and lifecycle, binds trusted Git scopes before a
  Git action is admitted, and exposes structured events to observers.
  """

  use GenServer, restart: :transient

  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoWorkcell.{Events, Git}

  def child_spec(opts) do
    workcell_id = Keyword.fetch!(opts, :workcell_id)

    %{
      id: {__MODULE__, workcell_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    workcell_id = Keyword.fetch!(opts, :workcell_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Casein.Agents.JidoWorkcell.Registry, workcell_id}}
    )
  end

  def whereis(workcell_id) when is_binary(workcell_id) do
    case Registry.lookup(Casein.Agents.JidoWorkcell.Registry, workcell_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def admit(pid, attrs), do: GenServer.call(pid, {:admit, attrs})
  def status(pid, worker_id), do: GenServer.call(pid, {:status, worker_id})
  def list(pid), do: GenServer.call(pid, :list)
  def cancel(pid, worker_id), do: GenServer.call(pid, {:cancel, worker_id})

  def await(pid, worker_id, timeout),
    do: GenServer.call(pid, {:await, worker_id, timeout}, call_timeout(timeout))

  def drain(pid), do: GenServer.call(pid, :drain)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    workcell_id = Keyword.fetch!(opts, :workcell_id)

    case JidoPod.ensure_pod(workspace_id, workcell_id: workcell_id) do
      {:ok, pod} ->
        Events.cell(workspace_id, workcell_id, :ready)

        {:ok,
         %{
           workspace_id: workspace_id,
           workcell_id: workcell_id,
           pod: pod,
           draining?: false,
           state: :ready
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:admit, _attrs}, _from, %{draining?: true} = state) do
    {:reply, {:error, :draining}, state}
  end

  def handle_call({:admit, attrs}, _from, state) when is_map(attrs) do
    with {:ok, attrs} <- prepare_attrs(attrs, state),
         {:ok, result} <- JidoPod.admit(attrs) do
      Events.attempt(Map.put(result, :workcell_id, state.workcell_id))
      {:reply, {:ok, Map.put(result, :workcell_id, state.workcell_id)}, %{state | state: :active}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:status, worker_id}, _from, state) do
    attempt_id = resolve_attempt_id(state.workspace_id, worker_id)
    {:reply, decorate(JidoPod.status(state.workspace_id, attempt_id), state), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.map(JidoPod.list(state.workspace_id), &decorate_ok(&1, state)), state}
  end

  def handle_call({:cancel, worker_id}, _from, state) do
    attempt_id = resolve_attempt_id(state.workspace_id, worker_id)
    {:reply, decorate(JidoPod.cancel(state.workspace_id, attempt_id), state), state}
  end

  def handle_call({:await, worker_id, timeout}, _from, state) do
    attempt_id = resolve_attempt_id(state.workspace_id, worker_id)
    {:reply, decorate(JidoPod.await(state.workspace_id, attempt_id, timeout), state), state}
  end

  def handle_call(:drain, _from, state) do
    Events.cell(state.workspace_id, state.workcell_id, :draining)
    result = JidoPod.drain(state.workspace_id)
    {:reply, result, %{state | draining?: true, state: :draining}}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot =
      state.workspace_id
      |> JidoPod.snapshot()
      |> Map.merge(%{
        workcell_id: state.workcell_id,
        state: state.state,
        draining?: state.draining?
      })

    {:reply, snapshot, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = JidoPod.stop_pod(state.workspace_id)
    _ = Events.cell(state.workspace_id, state.workcell_id, :stopped)
    :ok
  end

  defp prepare_attrs(attrs, state) do
    source =
      case Map.get(attrs, :lane, Map.get(attrs, "lane")) do
        lane when lane in [:casein_terminal, :terminal, "casein_terminal", "terminal"] ->
          "v3_casein"

        _ ->
          "casein_worker"
      end

    attrs =
      attrs
      |> Map.put(:workspace_id, state.workspace_id)
      |> Map.put(:runtime, :jido)
      |> Map.put(:workcell_id, state.workcell_id)
      |> Map.put(:workcell_assigned?, true)
      |> Map.put(:source, source)

    if git_action?(attrs) do
      with {:ok, scope} <- bind_scope(attrs) do
        {:ok,
         Map.merge(attrs, %{
           git_scope: scope,
           worktree_path: scope.worktree_path,
           repository: scope.repository,
           base_branch: scope.base_branch,
           head_branch: scope.assigned_branch,
           assigned_branch: scope.assigned_branch
         })}
      end
    else
      {:ok, attrs}
    end
  end

  defp bind_scope(%{git_scope: %Casein.Agents.JidoWorkcell.Git.Scope{} = scope}), do: {:ok, scope}
  defp bind_scope(attrs), do: Git.bind(attrs)

  defp git_action?(attrs) do
    attrs
    |> Map.get(:actions, [])
    |> List.wrap()
    |> Enum.any?(fn action ->
      name =
        if is_map(action), do: Map.get(action, :name) || Map.get(action, "name"), else: action

      name in ~w(git_status git_diff git_handoff)
    end)
  end

  defp decorate({:ok, value}, state), do: {:ok, decorate_ok(value, state)}
  defp decorate({:error, reason}, _state), do: {:error, reason}

  defp decorate_ok(value, state) when is_map(value) do
    value
    |> Map.put_new(:workcell_id, state.workcell_id)
    |> Map.put_new(:workcell_state, Events.lifecycle_state(value[:state]))
    |> Map.put_new(:runtime, :jido)
  end

  defp decorate_ok(value, _state), do: value

  # Workcell callers receive `worker_id`; the lower-level pod APIs historically
  # addressed an attempt by `attempt_id`. Accept both so the Workcell contract
  # does not leak the pod's internal identity choice.
  defp resolve_attempt_id(workspace_id, identifier) do
    case Enum.find(JidoPod.list(workspace_id), fn attempt ->
           attempt[:attempt_id] == identifier or attempt[:worker_id] == identifier
         end) do
      %{attempt_id: attempt_id} -> attempt_id
      _ -> identifier
    end
  end

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout + 1_000
  defp call_timeout(_timeout), do: 6_000
end
