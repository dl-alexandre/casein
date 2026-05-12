defmodule DevIDE.Fleet.RunnerDirectory do
  @moduledoc """
  First-class runner identity directory.

  The fleet registry remains the live topology cache. This directory tracks the
  operational identity and trust state a runner presents when it registers.
  Every change is audited so runner trust decisions remain reviewable.
  """

  use GenServer

  alias DevIDE.Audit

  @fleet_audit_workspace_id "fleet"

  @type trust_state :: :authorized | :draining | :maintenance | :revoked

  @type identity :: %{
          id: String.t(),
          hostname: String.t(),
          capabilities: [String.t()],
          trust_state: trust_state(),
          manifest: map(),
          registered_at: DateTime.t(),
          updated_at: DateTime.t(),
          revoked_at: DateTime.t() | nil,
          metadata: map()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec ensure_registered(map()) :: {:ok, identity()} | {:error, :runner_revoked}
  def ensure_registered(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:ensure_registered, attrs})
  end

  @spec set_trust_state(String.t(), trust_state(), keyword()) :: {:ok, identity()} | :error
  def set_trust_state(runner_id, trust_state, opts \\ [])
      when trust_state in [:authorized, :draining, :maintenance, :revoked] do
    GenServer.call(__MODULE__, {:set_trust_state, runner_id, trust_state, opts})
  end

  @spec get(String.t()) :: {:ok, identity()} | :error
  def get(runner_id), do: GenServer.call(__MODULE__, {:get, runner_id})

  @spec list(keyword()) :: [identity()]
  def list(opts \\ []), do: GenServer.call(__MODULE__, {:list, opts})

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl GenServer
  def init(_opts), do: {:ok, %{identities: %{}}}

  @impl GenServer
  def handle_call({:ensure_registered, attrs}, _from, state) do
    runner_id = Map.fetch!(attrs, :id)
    now = DateTime.utc_now()

    case Map.get(state.identities, runner_id) do
      %{trust_state: :revoked} ->
        {:reply, {:error, :runner_revoked}, state}

      nil ->
        identity =
          attrs
          |> identity_from_attrs(now)
          |> Map.put(:trust_state, :authorized)

        audit("fleet.runner_identity.registered", identity, Map.get(attrs, :actor_id))
        {:reply, {:ok, identity}, put_in(state, [:identities, runner_id], identity)}

      existing ->
        updated = %{
          existing
          | hostname: Map.get(attrs, :hostname, existing.hostname),
            capabilities: Map.get(attrs, :capabilities, existing.capabilities),
            manifest: manifest(attrs),
            metadata: Map.merge(existing.metadata || %{}, Map.get(attrs, :metadata, %{})),
            updated_at: now
        }

        audit("fleet.runner_identity.refreshed", updated, Map.get(attrs, :actor_id))
        {:reply, {:ok, updated}, put_in(state, [:identities, runner_id], updated)}
    end
  end

  def handle_call({:set_trust_state, runner_id, trust_state, opts}, _from, state) do
    case Map.fetch(state.identities, runner_id) do
      {:ok, identity} ->
        now = DateTime.utc_now()

        updated = %{
          identity
          | trust_state: trust_state,
            updated_at: now,
            revoked_at: if(trust_state == :revoked, do: now, else: identity.revoked_at)
        }

        audit("fleet.runner_identity.#{trust_state}", updated, Keyword.get(opts, :actor_id))
        {:reply, {:ok, updated}, put_in(state, [:identities, runner_id], updated)}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:get, runner_id}, _from, state) do
    case Map.fetch(state.identities, runner_id) do
      {:ok, identity} -> {:reply, {:ok, identity}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    trust_state = Keyword.get(opts, :trust_state)

    identities =
      state.identities
      |> Map.values()
      |> Enum.filter(fn identity ->
        is_nil(trust_state) or identity.trust_state == trust_state
      end)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:reply, identities, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{identities: %{}}}

  defp identity_from_attrs(attrs, now) do
    %{
      id: Map.fetch!(attrs, :id),
      hostname: Map.fetch!(attrs, :hostname),
      capabilities: Map.get(attrs, :capabilities, []),
      trust_state: :authorized,
      manifest: manifest(attrs),
      registered_at: now,
      updated_at: now,
      revoked_at: nil,
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp manifest(attrs) do
    %{
      capabilities: Map.get(attrs, :capabilities, []),
      metadata: Map.get(attrs, :metadata, %{}),
      protocol_versions: Map.get(attrs, :protocol_versions, [1]),
      transports: Map.get(attrs, :transports, ["http"])
    }
  end

  defp audit(action, identity, actor_id) do
    Audit.emit!(%{
      action: action,
      workspace_id: @fleet_audit_workspace_id,
      actor_id: actor_id || "runner",
      target_type: "runner",
      target_ref: identity.id,
      decision: if(identity.trust_state == :revoked, do: :deny, else: :allow),
      metadata: %{
        hostname: identity.hostname,
        trust_state: identity.trust_state,
        capabilities: identity.capabilities,
        manifest: identity.manifest
      }
    })
  end
end
