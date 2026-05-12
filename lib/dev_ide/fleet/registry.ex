defmodule DevIDE.Fleet.Registry do
  @moduledoc """
  In-memory fleet topology registry.

  Tracks:
    * registered runners (id, hostname, capabilities, state)
    * active leases (runner_id ↔ assignment_id bindings)
    * heartbeat timestamps for liveness detection

  All state is ephemeral — runners re-register on reconnect, leases
  re-acquire on restart.  The durable truth is the assignment event
  stream; this registry is a disposable operational cache.

  ## Design rules

    * Runner state transitions are single-writer (this process).
    * Lease creation is atomic: only one active lease per assignment.
    * Heartbeats are idempotent; missing heartbeats trigger stale
      detection in `DevIDE.Fleet.Detector`.
  """

  use GenServer

  alias DevIDE.Fleet.{Lease, Notification, Runner}

  @pubsub DevIde.PubSub

  @default_lease_duration_ms 15 * 60 * 1000

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  ## Runner operations

  @spec register(Runner.t()) :: {:ok, Runner.t()} | {:error, :duplicate_id}
  def register(%Runner{} = runner) do
    GenServer.call(__MODULE__, {:register, runner})
  end

  @spec heartbeat(String.t()) :: {:ok, Runner.t()} | :error
  def heartbeat(runner_id) do
    GenServer.call(__MODULE__, {:heartbeat, runner_id})
  end

  @spec unregister(String.t()) :: :ok
  def unregister(runner_id) do
    GenServer.call(__MODULE__, {:unregister, runner_id})
  end

  @spec set_runner_state(String.t(), Runner.state()) :: {:ok, Runner.t()} | :error
  def set_runner_state(runner_id, runner_state) do
    GenServer.call(__MODULE__, {:set_runner_state, runner_id, runner_state})
  end

  @spec list_runners() :: [Runner.t()]
  def list_runners, do: GenServer.call(__MODULE__, :list_runners)

  @spec get_runner(String.t()) :: {:ok, Runner.t()} | :error
  def get_runner(runner_id), do: GenServer.call(__MODULE__, {:get_runner, runner_id})

  @spec runners_by_state(atom()) :: [Runner.t()]
  def runners_by_state(state), do: GenServer.call(__MODULE__, {:runners_by_state, state})

  @spec runners_with_capability(String.t()) :: [Runner.t()]
  def runners_with_capability(capability),
    do: GenServer.call(__MODULE__, {:runners_with_capability, capability})

  ## Lease operations

  @spec acquire_lease(String.t(), String.t(), keyword()) ::
          {:ok, Lease.t()} | {:error, :already_leased | :runner_not_found | :runner_busy}
  def acquire_lease(runner_id, assignment_id, opts \\ []) do
    GenServer.call(__MODULE__, {:acquire_lease, runner_id, assignment_id, opts})
  end

  @spec release_lease(String.t()) :: :ok | :error
  def release_lease(assignment_id) do
    GenServer.call(__MODULE__, {:release_lease, assignment_id})
  end

  @spec revoke_lease(String.t()) :: :ok | :error
  def revoke_lease(assignment_id) do
    GenServer.call(__MODULE__, {:revoke_lease, assignment_id})
  end

  @spec get_lease(String.t()) :: {:ok, Lease.t()} | :error
  def get_lease(assignment_id), do: GenServer.call(__MODULE__, {:get_lease, assignment_id})

  @spec list_leases() :: [Lease.t()]
  def list_leases, do: GenServer.call(__MODULE__, :list_leases)

  @spec active_leases() :: [Lease.t()]
  def active_leases, do: GenServer.call(__MODULE__, :active_leases)

  @spec renew_lease(String.t(), String.t(), DateTime.t()) :: {:ok, Lease.t()} | {:error, term()}
  def renew_lease(lease_id, runner_id, %DateTime{} = expires_at) do
    GenServer.call(__MODULE__, {:renew_lease, lease_id, runner_id, expires_at})
  end

  ## Topology queries

  @spec assignments_for_runner(String.t()) :: [String.t()]
  def assignments_for_runner(runner_id),
    do: GenServer.call(__MODULE__, {:assignments_for_runner, runner_id})

  @spec runner_for_assignment(String.t()) :: {:ok, String.t()} | :error
  def runner_for_assignment(assignment_id),
    do: GenServer.call(__MODULE__, {:runner_for_assignment, assignment_id})

  ## Maintenance

  @spec detect_stale(non_neg_integer()) :: [Runner.t()]
  def detect_stale(threshold_ms) do
    GenServer.call(__MODULE__, {:detect_stale, threshold_ms})
  end

  @spec expire_leases(DateTime.t()) :: [Lease.t()]
  def expire_leases(now) do
    GenServer.call(__MODULE__, {:expire_leases, now})
  end

  @spec mark_offline([String.t()]) :: :ok
  def mark_offline(runner_ids) do
    GenServer.call(__MODULE__, {:mark_offline, runner_ids})
  end

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_opts) do
    {:ok, %{runners: %{}, leases: %{}, assignment_to_lease: %{}}}
  end

  @impl GenServer
  def handle_call({:register, %Runner{id: id} = runner}, _from, state) do
    if Map.has_key?(state.runners, id) do
      {:reply, {:error, :duplicate_id}, state}
    else
      now = DateTime.utc_now()
      registered = %{runner | registered_at: now, last_heartbeat_at: now, state: :online}
      state = put_in(state, [:runners, id], registered)

      broadcast(%Notification{
        kind: :runner_registered,
        runner_id: id,
        payload: %{runner: registered},
        occurred_at: now
      })

      {:reply, {:ok, registered}, state}
    end
  end

  def handle_call({:heartbeat, runner_id}, _from, state) do
    case Map.fetch(state.runners, runner_id) do
      {:ok, runner} ->
        now = DateTime.utc_now()

        new_state =
          if runner.state in [:offline, :stale] do
            :online
          else
            runner.state
          end

        updated = %{runner | last_heartbeat_at: now, state: new_state}
        state = put_in(state, [:runners, runner_id], updated)

        kind =
          if new_state == :online and runner.state in [:offline, :stale],
            do: :runner_heartbeat,
            else: :runner_heartbeat

        broadcast(%Notification{
          kind: kind,
          runner_id: runner_id,
          payload: %{runner: updated, previous_state: runner.state},
          occurred_at: now
        })

        {:reply, {:ok, updated}, state}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:unregister, runner_id}, _from, state) do
    state =
      state
      |> release_all_for_runner(runner_id)
      |> pop_in([:runners, runner_id])
      |> elem(1)

    {:reply, :ok, state}
  end

  def handle_call({:set_runner_state, runner_id, runner_state}, _from, state) do
    case Map.fetch(state.runners, runner_id) do
      {:ok, runner} ->
        updated = %{runner | state: runner_state}
        {:reply, {:ok, updated}, put_in(state, [:runners, runner_id], updated)}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call(:list_runners, _from, state) do
    {:reply, Map.values(state.runners), state}
  end

  def handle_call({:get_runner, runner_id}, _from, state) do
    case Map.fetch(state.runners, runner_id) do
      {:ok, runner} -> {:reply, {:ok, runner}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:runners_by_state, target_state}, _from, state) do
    results =
      state.runners
      |> Map.values()
      |> Enum.filter(&(&1.state == target_state))

    {:reply, results, state}
  end

  def handle_call({:runners_with_capability, capability}, _from, state) do
    results =
      state.runners
      |> Map.values()
      |> Enum.filter(&(capability in &1.capabilities))

    {:reply, results, state}
  end

  def handle_call({:acquire_lease, runner_id, assignment_id, opts}, _from, state) do
    with {:ok, runner} <- Map.fetch(state.runners, runner_id),
         true <- runner.state in [:online, :idle, :registering],
         false <- Map.has_key?(state.assignment_to_lease, assignment_id) do
      now = DateTime.utc_now()
      duration = Keyword.get(opts, :duration_ms, default_lease_duration_ms())
      expires_at = DateTime.add(now, duration, :millisecond)

      lease = %Lease{
        id: Ecto.UUID.generate(),
        assignment_id: assignment_id,
        runner_id: runner_id,
        acquired_at: now,
        expires_at: expires_at,
        state: :active
      }

      busy_runner = %{runner | state: :busy, active_assignment_id: assignment_id}

      state =
        state
        |> put_in([:leases, lease.id], lease)
        |> put_in([:assignment_to_lease, assignment_id], lease.id)
        |> put_in([:runners, runner_id], busy_runner)

      broadcast(%Notification{
        kind: :lease_acquired,
        runner_id: runner_id,
        assignment_id: assignment_id,
        lease_id: lease.id,
        payload: %{lease: lease, runner: busy_runner},
        occurred_at: now
      })

      {:reply, {:ok, lease}, state}
    else
      :error -> {:reply, {:error, :runner_not_found}, state}
      false when is_boolean(false) -> {:reply, {:error, :runner_busy}, state}
      true -> {:reply, {:error, :already_leased}, state}
    end
  end

  def handle_call({:release_lease, assignment_id}, _from, state) do
    case Map.fetch(state.assignment_to_lease, assignment_id) do
      {:ok, lease_id} ->
        lease = Map.get(state.leases, lease_id)

        state =
          state
          |> update_in(
            [:leases, lease_id],
            &%{&1 | state: :released, released_at: DateTime.utc_now()}
          )
          |> update_runner_after_lease_end(assignment_id)
          |> pop_in([:assignment_to_lease, assignment_id])
          |> elem(1)

        broadcast(%Notification{
          kind: :lease_released,
          assignment_id: assignment_id,
          lease_id: lease_id,
          runner_id: if(lease, do: lease.runner_id),
          payload: %{lease_id: lease_id},
          occurred_at: DateTime.utc_now()
        })

        {:reply, :ok, state}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:revoke_lease, assignment_id}, _from, state) do
    case Map.fetch(state.assignment_to_lease, assignment_id) do
      {:ok, lease_id} ->
        lease = Map.get(state.leases, lease_id)

        state =
          state
          |> update_in(
            [:leases, lease_id],
            &%{&1 | state: :revoked, released_at: DateTime.utc_now()}
          )
          |> update_runner_after_lease_end(assignment_id)
          |> pop_in([:assignment_to_lease, assignment_id])
          |> elem(1)

        broadcast(%Notification{
          kind: :lease_revoked,
          assignment_id: assignment_id,
          lease_id: lease_id,
          runner_id: if(lease, do: lease.runner_id),
          payload: %{lease_id: lease_id},
          occurred_at: DateTime.utc_now()
        })

        {:reply, :ok, state}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:get_lease, assignment_id}, _from, state) do
    case Map.fetch(state.assignment_to_lease, assignment_id) do
      {:ok, lease_id} ->
        case Map.fetch(state.leases, lease_id) do
          {:ok, lease} -> {:reply, {:ok, lease}, state}
          :error -> {:reply, :error, state}
        end

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call(:list_leases, _from, state) do
    {:reply, Map.values(state.leases), state}
  end

  def handle_call(:active_leases, _from, state) do
    results =
      state.leases
      |> Map.values()
      |> Enum.filter(&(&1.state == :active))

    {:reply, results, state}
  end

  def handle_call({:renew_lease, lease_id, runner_id, expires_at}, _from, state) do
    case Map.fetch(state.leases, lease_id) do
      {:ok, %Lease{runner_id: ^runner_id, state: :active} = lease} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          renewed = %{lease | expires_at: expires_at}
          state = put_in(state, [:leases, lease_id], renewed)

          broadcast(%Notification{
            kind: :lease_renewed,
            assignment_id: lease.assignment_id,
            lease_id: lease.id,
            runner_id: runner_id,
            payload: %{lease: renewed},
            occurred_at: DateTime.utc_now()
          })

          {:reply, {:ok, renewed}, state}
        else
          {:reply, {:error, :invalid_expiry}, state}
        end

      {:ok, %Lease{runner_id: ^runner_id}} ->
        {:reply, {:error, :lease_inactive}, state}

      {:ok, %Lease{}} ->
        {:reply, {:error, :lease_runner_mismatch}, state}

      :error ->
        {:reply, {:error, :lease_not_found}, state}
    end
  end

  def handle_call({:assignments_for_runner, runner_id}, _from, state) do
    assignments =
      state.leases
      |> Map.values()
      |> Enum.filter(&(&1.runner_id == runner_id and &1.state == :active))
      |> Enum.map(& &1.assignment_id)

    {:reply, assignments, state}
  end

  def handle_call({:runner_for_assignment, assignment_id}, _from, state) do
    case Map.fetch(state.assignment_to_lease, assignment_id) do
      {:ok, lease_id} ->
        case Map.fetch(state.leases, lease_id) do
          {:ok, %Lease{runner_id: runner_id, state: :active}} ->
            {:reply, {:ok, runner_id}, state}

          _ ->
            {:reply, :error, state}
        end

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:detect_stale, threshold_ms}, _from, state) do
    now = DateTime.utc_now()
    threshold = DateTime.add(now, -threshold_ms, :millisecond)

    stale_runners =
      state.runners
      |> Map.values()
      |> Enum.filter(fn runner ->
        runner.state in [:online, :idle, :busy, :registering] and
          DateTime.compare(runner.last_heartbeat_at || runner.registered_at, threshold) == :lt
      end)

    state =
      Enum.reduce(stale_runners, state, fn runner, acc ->
        put_in(acc, [:runners, runner.id], %{runner | state: :offline})
      end)

    for runner <- stale_runners do
      broadcast(%Notification{
        kind: :runner_offline,
        runner_id: runner.id,
        payload: %{runner: runner},
        occurred_at: now
      })
    end

    {:reply, stale_runners, state}
  end

  def handle_call({:expire_leases, now}, _from, state) do
    {expired_leases, _updated_leases} =
      state.leases
      |> Map.values()
      |> Enum.split_with(fn lease ->
        lease.state == :active and DateTime.compare(lease.expires_at, now) != :gt
      end)

    expired_ids = Enum.map(expired_leases, & &1.id)

    state =
      Enum.reduce(expired_ids, state, fn lease_id, acc ->
        lease = Map.fetch!(acc.leases, lease_id)

        acc
        |> update_in([:leases, lease_id], &%{&1 | state: :expired})
        |> update_runner_after_lease_end(lease.assignment_id)
        |> pop_in([:assignment_to_lease, lease.assignment_id])
        |> elem(1)
      end)

    for lease <- expired_leases do
      broadcast(%Notification{
        kind: :lease_expired,
        assignment_id: lease.assignment_id,
        lease_id: lease.id,
        runner_id: lease.runner_id,
        payload: %{lease: lease},
        occurred_at: now
      })
    end

    {:reply, expired_leases, state}
  end

  def handle_call({:mark_offline, runner_ids}, _from, state) do
    state =
      Enum.reduce(runner_ids, state, fn id, acc ->
        case Map.fetch(acc.runners, id) do
          {:ok, runner} ->
            put_in(acc, [:runners, id], %{runner | state: :offline})

          :error ->
            acc
        end
      end)

    for id <- runner_ids do
      broadcast(%Notification{
        kind: :runner_offline,
        runner_id: id,
        payload: %{},
        occurred_at: DateTime.utc_now()
      })
    end

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{runners: %{}, leases: %{}, assignment_to_lease: %{}}}
  end

  ## Internal

  defp release_all_for_runner(state, runner_id) do
    lease_ids =
      state.leases
      |> Map.values()
      |> Enum.filter(&(&1.runner_id == runner_id and &1.state == :active))
      |> Enum.map(& &1.id)

    Enum.reduce(lease_ids, state, fn lease_id, acc ->
      lease = Map.fetch!(acc.leases, lease_id)

      acc
      |> update_in(
        [:leases, lease_id],
        &%{&1 | state: :released, released_at: DateTime.utc_now()}
      )
      |> pop_in([:assignment_to_lease, lease.assignment_id])
      |> elem(1)
    end)
  end

  defp update_runner_after_lease_end(state, assignment_id) do
    case Map.fetch(state.assignment_to_lease, assignment_id) do
      {:ok, lease_id} ->
        case Map.fetch(state.leases, lease_id) do
          {:ok, %Lease{runner_id: runner_id}} ->
            case Map.fetch(state.runners, runner_id) do
              {:ok, runner} ->
                updated = %{runner | state: :idle, active_assignment_id: nil}
                put_in(state, [:runners, runner_id], updated)

              :error ->
                state
            end

          :error ->
            state
        end

      :error ->
        state
    end
  end

  defp broadcast(%Notification{} = notification) do
    Phoenix.PubSub.broadcast(@pubsub, "fleet", {__MODULE__, notification})

    if notification.assignment_id do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "fleet:assignments:#{notification.assignment_id}",
        {__MODULE__, notification}
      )
    end

    if notification.runner_id do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "fleet:runners:#{notification.runner_id}",
        {__MODULE__, notification}
      )
    end
  end

  defp default_lease_duration_ms do
    Application.get_env(:dev_ide, :fleet_lease_duration_ms, @default_lease_duration_ms)
  end
end
