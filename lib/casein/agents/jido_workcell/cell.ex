defmodule Casein.Agents.JidoWorkcell.Cell do
  @moduledoc """
  One supervised Workcell resource per workspace.

  The Jido pod remains the bounded worker engine. This coordinator owns the
  resource lifecycle around it: provisioning/readiness, worker and lease
  binding, health, idle teardown, cancellation, drain, and rollback. It never
  exposes a shell, tmux, pull-request, review, approval, merge, or deploy
  operation.
  """

  use GenServer, restart: :transient

  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoPod.Attempt
  alias Casein.Agents.JidoRuntime
  alias Casein.Agents.JidoWorkcell.{Events, Git, Limits, ResourceStore}

  @default_idle_timeout_ms 300_000
  @default_lease_ttl_ms 60_000
  @max_duration_ms 86_400_000

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
  def rollback(pid, reason \\ :rollback), do: GenServer.call(pid, {:rollback, reason})
  def provision(pid), do: GenServer.call(pid, :provision)
  def health(pid), do: GenServer.call(pid, :health)
  def reap_idle(pid), do: GenServer.call(pid, :reap_idle)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    workcell_id = Keyword.fetch!(opts, :workcell_id)
    runtime = JidoRuntime.profile(opts)
    idle_timeout_ms = duration(opts, :idle_timeout_ms, @default_idle_timeout_ms)
    lease_ttl_ms = duration(opts, :lease_ttl_ms, @default_lease_ttl_ms)
    now = DateTime.utc_now()
    prior = ResourceStore.get(workcell_id) || %{}

    state = %{
      workspace_id: workspace_id,
      workcell_id: workcell_id,
      pod: nil,
      runtime: runtime,
      draining?: false,
      state: :provisioning,
      desired_state: :ready,
      workers: %{},
      leases: %{},
      idle_timer: nil,
      idle_timeout_ms: idle_timeout_ms,
      lease_ttl_ms: lease_ttl_ms,
      created_at: Map.get(prior, :created_at, now),
      last_used_at: now,
      rollback_reason: nil,
      recovery: Map.get(prior, :recovery, %{})
    }

    persist(state)
    _ = Events.cell(workspace_id, workcell_id, :requested)
    _ = Events.cell(workspace_id, workcell_id, :provisioning)

    case JidoPod.ensure_pod(workspace_id, workcell_id: workcell_id) do
      {:ok, pod} ->
        :ok = JidoPod.subscribe(workspace_id)
        ready = %{state | pod: pod, state: :ready, desired_state: :ready}
        persist(ready)
        _ = Events.cell(workspace_id, workcell_id, :ready)
        {:ok, schedule_idle(ready)}

      {:error, reason} ->
        persist(%{state | state: :failed, desired_state: :ready, rollback_reason: reason})
        _ = Events.cell(workspace_id, workcell_id, :failed)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:admit, _attrs}, _from, %{draining?: true} = state) do
    {:reply, {:error, :draining}, state}
  end

  def handle_call({:admit, attrs}, _from, state) when is_map(attrs) do
    state = cancel_idle(state)

    with {:ok, attrs} <- prepare_attrs(attrs, state),
         {:ok, attrs, lease_ttl_ms} <- prepare_lease(attrs, state),
         {:ok, result} <- JidoPod.admit(attrs) do
      state = register_attempt(state, result, lease_ttl_ms)
      result = Map.put(result, :workcell_id, state.workcell_id)
      _ = Events.attempt(result)
      state = state |> activity_state() |> persist()
      {:reply, {:ok, result}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, schedule_idle(state)}
    end
  end

  def handle_call({:admit, _attrs}, _from, state),
    do: {:reply, {:error, :invalid_argument}, schedule_idle(state)}

  def handle_call({:status, worker_id}, _from, state) do
    attempt_id = resolve_attempt_id(state.workspace_id, worker_id)
    {:reply, decorate(JidoPod.status(state.workspace_id, attempt_id), state), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.map(JidoPod.list(state.workspace_id), &decorate_ok(&1, state)), state}
  end

  def handle_call({:cancel, worker_id}, _from, state) do
    attempt_id = resolve_attempt_id(state.workspace_id, worker_id)
    result = JidoPod.cancel(state.workspace_id, attempt_id)

    state =
      case result do
        {:ok, attempt} ->
          state
          |> maybe_release_terminal_lease(attempt)
          |> Map.put(:last_used_at, DateTime.utc_now())
          |> persist()

        _ ->
          state
      end

    {:reply, decorate(result, state), state}
  end

  def handle_call({:await, worker_id, timeout}, _from, state) do
    attempt_id = resolve_attempt_id(state.workspace_id, worker_id)
    result = JidoPod.await(state.workspace_id, attempt_id, timeout)

    state =
      case result do
        {:ok, attempt} ->
          state
          |> maybe_release_terminal_lease(attempt)
          |> activity_state()
          |> persist()

        _ ->
          state
      end

    {:reply, decorate(result, state), state}
  end

  def handle_call(:drain, _from, state) do
    _ = Events.cell(state.workspace_id, state.workcell_id, :draining)
    result = JidoPod.drain(state.workspace_id)

    state = %{
      state
      | draining?: true,
        state: :draining,
        desired_state: :stopped,
        last_used_at: DateTime.utc_now()
    }

    state = state |> persist() |> schedule_idle()
    {:reply, result, state}
  end

  def handle_call({:rollback, reason}, _from, state) do
    _ = Events.cell(state.workspace_id, state.workcell_id, :draining)
    _ = JidoPod.drain(state.workspace_id)

    state.workspace_id
    |> JidoPod.list()
    |> Enum.each(fn attempt ->
      if not Attempt.terminal?(attempt[:state]) do
        _ = JidoPod.cancel(state.workspace_id, attempt[:attempt_id])
      end
    end)

    stopped =
      state
      |> cancel_idle()
      |> Map.merge(%{
        draining?: true,
        state: :stopped,
        desired_state: :stopped,
        rollback_reason: reason,
        leases: %{},
        last_used_at: DateTime.utc_now()
      })

    # Publish the terminal resource before replying; the supervisor may still
    # be unregistering this cell when the caller immediately asks for health.
    _ = persist(stopped)
    reply = {:ok, resource_snapshot(stopped) |> Map.put(:rollback?, true)}
    {:stop, :normal, reply, stopped}
  end

  def handle_call(:provision, _from, state), do: {:reply, {:ok, resource_snapshot(state)}, state}
  def handle_call(:health, _from, state), do: {:reply, {:ok, resource_snapshot(state)}, state}

  def handle_call(:reap_idle, _from, state) do
    if idle?(state) do
      stopped =
        state
        |> cancel_idle()
        |> Map.merge(%{
          draining?: true,
          state: :stopped,
          desired_state: :stopped,
          leases: %{},
          last_used_at: DateTime.utc_now()
        })

      _ = persist(stopped)
      {:stop, :normal, {:ok, resource_snapshot(stopped)}, stopped}
    else
      {:reply, {:ok, resource_snapshot(state)}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    pod = JidoPod.snapshot(state.workspace_id)

    {:reply,
     Map.merge(pod, resource_snapshot(state))
     |> Map.put(:pod, Map.get(pod, :pod, %{})), state}
  end

  @impl true
  def handle_info({:jido_attempt, attempt}, state) when is_map(attempt) do
    state = observe_attempt(state, attempt)
    {:noreply, state}
  end

  def handle_info({:lease_expired, lease_id}, state) do
    case Map.pop(state.leases, lease_id) do
      {nil, _leases} ->
        {:noreply, state}

      {%{attempt_id: attempt_id}, leases} ->
        _ = JidoPod.cancel(state.workspace_id, attempt_id)

        state =
          %{state | leases: leases, last_used_at: DateTime.utc_now()}
          |> persist()
          |> schedule_idle()

        {:noreply, state}
    end
  end

  def handle_info(:idle_timeout, state) do
    if idle?(state) do
      {:stop, :normal, state}
    else
      {:noreply, schedule_idle(state)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    cancel_idle(state)
    _ = JidoPod.stop_pod(state.workspace_id)
    stopped = %{state | state: :stopped, desired_state: :stopped, draining?: true, leases: %{}}
    persist(stopped)
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
      |> Map.drop([:runtime_id, "runtime_id", :worker_id, "worker_id"])
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

  defp prepare_lease(attrs, state) do
    lease_id = value(attrs, :lease_id) || new_id("lease")
    lease_ttl_ms = duration(attrs, :lease_ttl_ms, state.lease_ttl_ms)

    cond do
      not Limits.valid_scalar_id?(lease_id) ->
        {:error, :invalid_lease_id}

      not is_integer(lease_ttl_ms) or lease_ttl_ms < 1 ->
        {:error, :invalid_lease_ttl}

      true ->
        {:ok, attrs |> Map.put(:lease_id, lease_id) |> Map.delete(:lease_ttl_ms), lease_ttl_ms}
    end
  end

  defp register_attempt(state, result, lease_ttl_ms) when is_map(result) do
    worker_id = result[:worker_id]
    attempt_id = result[:attempt_id]
    lease_id = result[:lease_id]

    workers =
      if is_binary(worker_id) and is_binary(attempt_id),
        do: Map.put(state.workers, worker_id, attempt_id),
        else: state.workers

    state = %{state | workers: workers, last_used_at: DateTime.utc_now()}

    if is_binary(lease_id) and is_binary(attempt_id) and not terminal_result?(result) do
      deadline_ms = System.monotonic_time(:millisecond) + lease_ttl_ms
      timer = Process.send_after(self(), {:lease_expired, lease_id}, lease_ttl_ms)

      lease = %{
        attempt_id: attempt_id,
        worker_id: worker_id,
        deadline_ms: deadline_ms,
        expires_at: DateTime.add(DateTime.utc_now(), lease_ttl_ms, :millisecond),
        timer: timer
      }

      %{state | leases: Map.put(state.leases, lease_id, lease)}
    else
      state
    end
  end

  defp register_attempt(state, _result, _lease_ttl_ms), do: state

  defp observe_attempt(state, attempt) do
    state = register_attempt_observation(state, attempt)

    state =
      if terminal_result?(attempt),
        do: maybe_release_terminal_lease(state, attempt),
        else: state

    state
    |> activity_state()
    |> persist()
    |> schedule_idle()
  end

  defp register_attempt_observation(state, attempt) do
    worker_id = attempt[:worker_id]
    attempt_id = attempt[:attempt_id]

    if is_binary(worker_id) and is_binary(attempt_id),
      do: %{state | workers: Map.put(state.workers, worker_id, attempt_id)},
      else: state
  end

  defp maybe_release_terminal_lease(state, attempt) do
    if terminal_result?(attempt) do
      case Enum.find(state.leases, fn {_id, lease} -> lease.attempt_id == attempt[:attempt_id] end) do
        {lease_id, lease} ->
          cancel_timer(lease.timer)
          %{state | leases: Map.delete(state.leases, lease_id)}

        nil ->
          state
      end
    else
      state
    end
  end

  defp activity_state(%{draining?: true} = state),
    do: %{state | state: :draining, desired_state: :stopped}

  defp activity_state(state) do
    active? =
      state.workspace_id
      |> JidoPod.list()
      |> Enum.any?(fn attempt -> not terminal_result?(attempt) end)

    if active? do
      %{state | state: :active, desired_state: :active}
    else
      %{state | state: :ready, desired_state: :ready}
    end
  end

  defp resource_snapshot(state) do
    pod = safe_pod_snapshot(state.workspace_id)
    attempts = safe_list(state.workspace_id)
    worker_ids = state.workers |> Map.keys() |> Enum.sort()
    active_attempts = Enum.reject(attempts, &terminal_result?/1)

    %{
      workcell_id: state.workcell_id,
      workspace_id: state.workspace_id,
      state: state.state,
      actual_state: state.state,
      desired_state: state.desired_state,
      ready?: state.state in [:ready, :active],
      readiness: readiness(state.state),
      healthy?: healthy?(state),
      runtime: state.runtime.runtime,
      runtime_name: state.runtime.runtime_name,
      provider: state.runtime.provider,
      model: state.runtime.model,
      api_model: state.runtime.api_model,
      headless: state.runtime.headless,
      worker_count: length(worker_ids),
      worker_ids: worker_ids,
      active_worker_count: length(active_attempts),
      lease_count: map_size(state.leases),
      leases: public_leases(state.leases),
      running: get_in(pod, [:pod, :running]) || 0,
      queued: get_in(pod, [:pod, :queued]) || 0,
      draining?: state.draining?,
      idle_timeout_ms: state.idle_timeout_ms,
      lease_ttl_ms: state.lease_ttl_ms,
      created_at: state.created_at,
      last_used_at: state.last_used_at,
      rollback_reason: state.rollback_reason,
      recovery: state.recovery,
      last_health: %{
        ready?: state.state in [:ready, :active],
        healthy?: healthy?(state),
        readiness: readiness(state.state),
        active_worker_count: length(active_attempts),
        lease_count: map_size(state.leases),
        observed_at: DateTime.utc_now()
      }
    }
  end

  defp resource_record(state) do
    resource_snapshot(state)
    |> Map.drop([:leases, :running, :queued])
    |> Map.put(:leases, public_leases(state.leases))
    |> Map.put(:updated_at, DateTime.utc_now())
  end

  defp persist(state) do
    _ = safe_store_put(state.workcell_id, resource_record(state))
    state
  end

  defp safe_store_put(workcell_id, resource) do
    ResourceStore.put(workcell_id, resource)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp public_leases(leases) do
    leases
    |> Enum.map(fn {lease_id, lease} ->
      %{
        lease_id: lease_id,
        attempt_id: lease.attempt_id,
        worker_id: lease.worker_id,
        expires_at: lease.expires_at
      }
    end)
    |> Enum.sort_by(& &1.lease_id)
  end

  defp healthy?(state) do
    is_pid(state.pod) and Process.alive?(state.pod) and state.state not in [:failed, :stopped]
  end

  defp readiness(state) when state in [:ready, :active], do: :ready
  defp readiness(:provisioning), do: :provisioning
  defp readiness(:draining), do: :draining
  defp readiness(:stopped), do: :stopped
  defp readiness(:failed), do: :failed
  defp readiness(_), do: :provisioning

  defp idle?(state) do
    map_size(state.leases) == 0 and
      case safe_pod_snapshot(state.workspace_id) do
        %{pod: %{running: 0, queued: 0}} -> true
        _ -> false
      end
  end

  defp schedule_idle(%{idle_timeout_ms: :infinity} = state), do: state

  defp schedule_idle(state) do
    if idle?(state) do
      if state.idle_timer do
        state
      else
        %{state | idle_timer: Process.send_after(self(), :idle_timeout, state.idle_timeout_ms)}
      end
    else
      cancel_idle(state)
    end
  end

  defp cancel_idle(%{idle_timer: nil} = state), do: state

  defp cancel_idle(state) do
    _ = Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil}
  end

  defp safe_pod_snapshot(workspace_id) do
    JidoPod.snapshot(workspace_id)
  rescue
    _ -> %{pod: %{running: 0, queued: 0}}
  catch
    :exit, _ -> %{pod: %{running: 0, queued: 0}}
  end

  defp safe_list(workspace_id) do
    JidoPod.list(workspace_id)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp terminal_result?(%{state: state}), do: Attempt.terminal?(state)
  defp terminal_result?(_), do: false

  defp bind_scope(%{git_scope: %Casein.Agents.JidoWorkcell.Git.Scope{} = scope}) do
    # A struct supplied by a caller is still input at this boundary. Rebuild
    # and rebind it through the configured adapter so the worktree root and
    # assigned branch are verified before any Git action is admitted.
    Git.bind(Map.from_struct(scope))
  end

  defp bind_scope(attrs), do: Git.bind(attrs)

  defp git_action?(attrs) do
    attrs
    |> Map.get(:actions, Map.get(attrs, "actions", []))
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
  # addressed an attempt by `attempt_id`. Accept both without exposing pod
  # identity as the Workcell resource identity.
  defp resolve_attempt_id(workspace_id, identifier) do
    Enum.find_value(JidoPod.list(workspace_id), identifier, fn attempt ->
      if attempt[:attempt_id] == identifier or attempt[:worker_id] == identifier,
        do: attempt[:attempt_id]
    end)
  end

  defp duration(attrs, key, default) when is_list(attrs) do
    duration(Keyword.get(attrs, key), key, default)
  end

  defp duration(attrs, key, default) when is_map(attrs) do
    duration(value(attrs, key), key, default)
  end

  defp duration(value, key, default) do
    cond do
      key == :idle_timeout_ms and value == :infinity -> :infinity
      is_integer(value) and value > 0 -> min(value, @max_duration_ms)
      true -> default
    end
  end

  defp new_id(prefix),
    do: prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp value(attrs, key, default \\ nil)

  defp value(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp value(_attrs, _key, default), do: default

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout + 1_000
  defp call_timeout(_timeout), do: 6_000
end
