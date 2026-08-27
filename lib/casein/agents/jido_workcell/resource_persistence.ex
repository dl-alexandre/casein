defmodule Casein.Agents.JidoWorkcell.ResourcePersistence do
  @moduledoc """
  V3 runtime-bound persistence for Workcell resource projections.

  Workcells are process-owned, but their resource identity and recovery facts
  must outlive the BEAM process. This adapter stores a deliberately small,
  redacted projection in the existing `workspace_runtimes.metadata` boundary.
  It never serializes worker input, action arguments, filesystem paths,
  credentials, tokens, or process references.
  """

  alias Casein.Agents.JidoWorkcell.Receipt
  alias Casein.Runtimes.{LifecycleEvent, Runtime}

  @isolation_mode "jido_workcell"
  @marker "casein_jido_workcell"
  @max_resources 1_000
  @states ~w(requested queued provisioning ready active waiting completed failed cancelled draining stopped retired application_restart)
  @resource_keys [
    :workcell_id,
    :workspace_id,
    :state,
    :actual_state,
    :desired_state,
    :ready?,
    :readiness,
    :healthy?,
    :runtime,
    :runtime_name,
    :provider,
    :model,
    :api_model,
    :headless,
    :worker_ids,
    :worker_count,
    :active_worker_count,
    :lease_count,
    :leases,
    :idle_timeout_ms,
    :lease_ttl_ms,
    :created_at,
    :last_used_at,
    :updated_at,
    :rollback_reason,
    :recovery,
    :last_health,
    :idempotency,
    :draining?
  ]
  @restart_states ~w(provisioning ready active waiting draining)
  @state_atoms %{
    "requested" => :requested,
    "queued" => :queued,
    "provisioning" => :provisioning,
    "ready" => :ready,
    "active" => :active,
    "waiting" => :waiting,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "draining" => :draining,
    "stopped" => :stopped,
    "retired" => :retired,
    "application_restart" => :application_restart
  }

  @type resource :: map()

  @spec list() :: [resource()]
  def list do
    adapter().list_runtimes(%{"isolation_mode" => @isolation_mode, "limit" => @max_resources})
    |> Enum.filter(&workcell_runtime?/1)
    |> Enum.map(&from_runtime/1)
    |> Enum.filter(&is_map/1)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @spec put(resource()) :: :ok | {:error, term()}
  def put(resource) when is_map(resource) do
    with {:ok, resource} <- normalize(resource),
         {:ok, runtime} <- to_runtime(resource),
         {:ok, _runtime} <- upsert(runtime) do
      :ok
    end
  rescue
    error -> {:error, {:persistence_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:persistence_unavailable, reason}}
  end

  def put(_resource), do: {:error, :invalid_resource}

  @doc "Retire process-owned state after an application restart."
  @spec reconcile(resource(), DateTime.t()) :: resource()
  def reconcile(resource, now \\ DateTime.utc_now()) when is_map(resource) do
    actual_state = state_value(resource, :actual_state, :state, :stopped)
    leases = list_value(resource, :leases)

    if Atom.to_string(actual_state) in @restart_states or leases != [] do
      stale_lease_ids = Enum.flat_map(leases, &lease_id/1)
      desired_state = state_value(resource, :desired_state, :state, actual_state)

      resource
      |> Map.merge(%{
        state: :stopped,
        actual_state: :stopped,
        desired_state: desired_state,
        ready?: false,
        readiness: :stopped,
        healthy?: false,
        draining?: true,
        leases: [],
        lease_count: 0,
        active_worker_count: 0,
        recovery: %{
          status: :retired,
          reason: :application_restart,
          recovered_at: now,
          stale_lease_ids: stale_lease_ids
        },
        updated_at: now
      })
    else
      resource
    end
  end

  @doc "Merge a new resource projection without losing durable idempotency."
  @spec merge(resource() | nil, resource()) :: resource()
  def merge(existing, incoming) when is_map(incoming) do
    existing = if is_map(existing), do: existing, else: %{}
    incoming = project(incoming)
    old_idempotency = map_value(existing, :idempotency)
    new_idempotency = map_value(incoming, :idempotency)

    incoming
    |> Map.put(:idempotency, Map.merge(old_idempotency, new_idempotency))
    |> preserve(existing, :recovery)
  end

  @doc "Add one validated handoff result to the resource projection."
  @spec add_idempotency(resource(), map()) :: resource()
  def add_idempotency(resource, entry) when is_map(resource) and is_map(entry) do
    resource = project(resource)
    handoff_id = string_value(entry, :handoff_id)

    if is_binary(handoff_id) and handoff_id != "" do
      idempotency = map_value(resource, :idempotency)
      Map.put(resource, :idempotency, Map.put(idempotency, handoff_id, entry))
    else
      resource
    end
  end

  def add_idempotency(resource, _entry), do: resource

  @doc "Keep only the resource projection fields allowed in the process cache."
  @spec project(resource()) :: resource()
  def project(resource) when is_map(resource) do
    Enum.reduce(@resource_keys, %{}, fn key, projected ->
      case value(resource, key) do
        nil -> projected
        value -> Map.put(projected, key, value)
      end
    end)
  end

  @doc "Return the runtime isolation marker used by the V3 boundary."
  def isolation_mode, do: @isolation_mode

  @spec normalize(resource()) :: {:ok, resource()} | {:error, term()}
  def normalize(resource) when is_map(resource) do
    workcell_id = string_value(resource, :workcell_id)
    workspace_id = string_value(resource, :workspace_id)

    cond do
      not present?(workcell_id) -> {:error, :workcell_id_required}
      not present?(workspace_id) -> {:error, :workspace_id_required}
      true -> {:ok, normalize_resource(resource, workcell_id, workspace_id)}
    end
  end

  def normalize(_resource), do: {:error, :invalid_resource}

  defp normalize!(resource) do
    case normalize(resource) do
      {:ok, resource} -> resource
      {:error, reason} -> raise ArgumentError, "invalid Workcell resource: #{inspect(reason)}"
    end
  end

  defp normalize_resource(resource, workcell_id, workspace_id) do
    now = DateTime.utc_now()
    actual_state = state_value(resource, :actual_state, :state, :stopped)
    desired_state = state_value(resource, :desired_state, :state, actual_state)
    leases = normalize_leases(list_value(resource, :leases))
    idempotency = normalize_idempotency(map_value(resource, :idempotency))
    recovery = normalize_recovery(map_value(resource, :recovery))

    %{
      workcell_id: workcell_id,
      workspace_id: workspace_id,
      state: actual_state,
      actual_state: actual_state,
      desired_state: desired_state,
      ready?: boolean_value(resource, :ready?, false),
      readiness: state_value(resource, :readiness, nil, actual_state),
      healthy?: boolean_value(resource, :healthy?, false),
      runtime: safe_text(value(resource, :runtime), "jido"),
      runtime_name: safe_text(value(resource, :runtime_name), "jido"),
      provider: safe_text(value(resource, :provider), "opencode"),
      model: safe_text(value(resource, :model), "opencode/grok-4.6"),
      api_model: safe_text(value(resource, :api_model), "grok-4.6"),
      headless: boolean_value(resource, :headless, true),
      worker_ids: normalize_ids(list_value(resource, :worker_ids)),
      worker_count: non_negative_integer(value(resource, :worker_count), 0),
      active_worker_count: non_negative_integer(value(resource, :active_worker_count), 0),
      lease_count: length(leases),
      leases: leases,
      idle_timeout_ms: positive_integer(value(resource, :idle_timeout_ms), nil),
      lease_ttl_ms: positive_integer(value(resource, :lease_ttl_ms), nil),
      created_at: datetime_value(value(resource, :created_at)) || now,
      last_used_at: datetime_value(value(resource, :last_used_at)),
      updated_at: datetime_value(value(resource, :updated_at)) || now,
      rollback_reason: safe_text(value(resource, :rollback_reason)),
      recovery: recovery,
      last_health: normalize_health(map_value(resource, :last_health)),
      idempotency: idempotency
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp to_runtime(resource) do
    with {:ok, resource} <- normalize(resource),
         {:ok, workcell_id} <- required(resource, :workcell_id),
         {:ok, workspace_id} <- required(resource, :workspace_id) do
      now = datetime_value(value(resource, :updated_at)) || DateTime.utc_now()
      created_at = datetime_value(value(resource, :created_at)) || now
      state = state_value(resource, :actual_state, :state, :stopped)

      runtime_status =
        if state in [:stopped, :failed, :cancelled], do: "cleaned", else: "provisioned"

      {:ok,
       %Runtime{
         id: workcell_id,
         workspace_id: workspace_id,
         host_id: host_id(),
         isolation_mode: @isolation_mode,
         status: runtime_status,
         created_at: created_at,
         heartbeat_at: now,
         cleaned_at: if(runtime_status == "cleaned", do: now),
         failure_reason: value(resource, :rollback_reason),
         active_assignments: non_negative_integer(value(resource, :active_worker_count), 0),
         metadata: %{
           "kind" => @marker,
           "resource" => encode_resource(resource)
         }
       }}
    end
  end

  defp upsert(%Runtime{} = runtime) do
    adapter = adapter()

    case adapter.get_runtime(runtime.id) do
      {:ok, _existing} -> adapter.update_runtime(runtime, nil)
      :error -> adapter.create_runtime(runtime, event(runtime))
    end
  end

  defp event(%Runtime{} = runtime) do
    %LifecycleEvent{
      id: Ecto.UUID.generate(),
      runtime_id: runtime.id,
      workspace_id: runtime.workspace_id,
      event: "runtime_provisioned",
      to_status: "provisioned",
      inserted_at: DateTime.utc_now(),
      metadata: %{"source" => @marker}
    }
  end

  defp from_runtime(%Runtime{metadata: metadata} = runtime) when is_map(metadata) do
    payload = Map.get(metadata, "resource") || Map.get(metadata, :resource)

    if is_map(payload) do
      actual_state = state_value(payload, "actual_state", "state", :stopped)
      leases = decode_leases(Map.get(payload, "leases", []))

      health = Map.get(payload, "health", %{})

      %{
        workcell_id: runtime.id,
        workspace_id: runtime.workspace_id,
        state: actual_state,
        actual_state: actual_state,
        desired_state: state_value(payload, "desired_state", "actual_state", actual_state),
        ready?: health_value(health, "ready?", false),
        readiness: state_value(payload, "readiness", nil, actual_state),
        healthy?: health_value(health, "healthy?", false),
        runtime: string_value(payload, "runtime") || "jido",
        runtime_name: string_value(payload, "runtime_name") || "jido",
        provider: string_value(payload, "provider") || "opencode",
        model: string_value(payload, "model") || "opencode/grok-4.6",
        api_model: string_value(payload, "api_model") || "grok-4.6",
        headless: health_value(health, "headless", true),
        worker_ids: normalize_ids(Map.get(payload, "worker_ids", [])),
        worker_count: non_negative_integer(Map.get(payload, "worker_count"), 0),
        active_worker_count: non_negative_integer(Map.get(payload, "active_worker_count"), 0),
        lease_count: length(leases),
        leases: leases,
        idle_timeout_ms: positive_integer(Map.get(payload, "idle_timeout_ms"), nil),
        lease_ttl_ms: positive_integer(Map.get(payload, "lease_ttl_ms"), nil),
        created_at: decode_datetime(Map.get(payload, "created_at")) || runtime.created_at,
        last_used_at: decode_datetime(Map.get(payload, "last_used_at")),
        updated_at: decode_datetime(Map.get(payload, "updated_at")) || runtime.updated_at,
        rollback_reason: string_value(payload, "rollback_reason"),
        recovery: decode_recovery(Map.get(payload, "recovery")),
        last_health: decode_health(Map.get(payload, "last_health")),
        idempotency: decode_idempotency(Map.get(payload, "idempotency", %{}))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp from_runtime(_runtime), do: nil

  defp workcell_runtime?(%Runtime{isolation_mode: @isolation_mode, metadata: metadata})
       when is_map(metadata) do
    Map.get(metadata, "kind") == @marker or Map.get(metadata, :kind) == @marker
  end

  defp workcell_runtime?(_runtime), do: false

  defp encode_resource(resource) do
    resource
    |> normalize!
    |> encode_resource_values()
  end

  defp encode_resource_values(resource) do
    %{
      "workcell_id" => string_value(resource, :workcell_id),
      "workspace_id" => string_value(resource, :workspace_id),
      "state" => state_string(resource, :actual_state, :state, :stopped),
      "actual_state" => state_string(resource, :actual_state, :state, :stopped),
      "desired_state" => state_string(resource, :desired_state, :state, :stopped),
      "runtime" => string_value(resource, :runtime),
      "runtime_name" => string_value(resource, :runtime_name),
      "provider" => string_value(resource, :provider),
      "model" => string_value(resource, :model),
      "api_model" => string_value(resource, :api_model),
      "worker_ids" => normalize_ids(list_value(resource, :worker_ids)),
      "worker_count" => non_negative_integer(value(resource, :worker_count), 0),
      "active_worker_count" => non_negative_integer(value(resource, :active_worker_count), 0),
      "idle_timeout_ms" => positive_integer(value(resource, :idle_timeout_ms), nil),
      "lease_ttl_ms" => positive_integer(value(resource, :lease_ttl_ms), nil),
      "created_at" => encode_datetime(value(resource, :created_at)),
      "last_used_at" => encode_datetime(value(resource, :last_used_at)),
      "updated_at" => encode_datetime(value(resource, :updated_at)),
      "rollback_reason" => safe_text(value(resource, :rollback_reason)),
      "leases" => encode_leases(list_value(resource, :leases)),
      "idempotency" => encode_idempotency(map_value(resource, :idempotency)),
      "last_health" => encode_health(map_value(resource, :last_health)),
      "recovery" => encode_recovery(map_value(resource, :recovery)),
      "health" => %{
        "ready?" => boolean_value(resource, :ready?, false),
        "healthy?" => boolean_value(resource, :healthy?, false),
        "readiness" => state_string(resource, :readiness, nil, :stopped),
        "headless" => boolean_value(resource, :headless, true),
        "active_worker_count" => non_negative_integer(value(resource, :active_worker_count), 0),
        "lease_count" => length(list_value(resource, :leases)),
        "observed_at" => encode_datetime(value(resource, :updated_at))
      }
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp encode_leases(leases) do
    leases
    |> Enum.map(fn lease ->
      %{
        "lease_id" => string_value(lease, :lease_id),
        "attempt_id" => string_value(lease, :attempt_id),
        "worker_id" => string_value(lease, :worker_id),
        "expires_at" => encode_datetime(value(lease, :expires_at))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
    |> Enum.filter(&(Map.has_key?(&1, "lease_id") and Map.has_key?(&1, "expires_at")))
  end

  defp normalize_leases(leases) do
    leases
    |> Enum.map(fn lease ->
      %{
        lease_id: string_value(lease, :lease_id),
        attempt_id: string_value(lease, :attempt_id),
        worker_id: string_value(lease, :worker_id),
        expires_at:
          datetime_value(value(lease, :expires_at)) ||
            decode_datetime(value(lease, :expires_at))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
    |> Enum.filter(&(is_binary(&1[:lease_id]) and is_struct(&1[:expires_at], DateTime)))
  end

  defp decode_leases(leases), do: normalize_leases(leases)

  defp lease_id(%{lease_id: id}) when is_binary(id), do: [id]
  defp lease_id(%{"lease_id" => id}) when is_binary(id), do: [id]
  defp lease_id(_lease), do: []

  defp encode_idempotency(entries) when is_map(entries) do
    entries
    |> Enum.reduce(%{}, fn {handoff_id, entry}, acc ->
      handoff_id = safe_text(handoff_id)

      case encode_idempotency_entry(handoff_id, entry) do
        nil -> acc
        encoded -> Map.put(acc, handoff_id, encoded)
      end
    end)
  end

  defp encode_idempotency_entry(handoff_id, entry) when is_binary(handoff_id) and is_map(entry) do
    head_sha = string_value(entry, :head_sha)
    handoff_key = string_value(entry, :handoff_key)

    if Receipt.valid_sha?(head_sha) and
         handoff_key == Receipt.idempotency_key(handoff_id, head_sha) do
      %{
        "fingerprint" => encode_fingerprint(value(entry, :fingerprint)),
        "head_sha" => head_sha,
        "handoff_key" => handoff_key,
        "receipt" => encode_receipt(value(entry, :receipt))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp encode_idempotency_entry(_handoff_id, _entry), do: nil

  defp normalize_idempotency(entries) when is_map(entries) do
    entries
    |> Enum.reduce(%{}, fn {handoff_id, entry}, acc ->
      case normalize_idempotency_entry(handoff_id, entry) do
        nil -> acc
        normalized -> Map.put(acc, normalized.handoff_id, normalized)
      end
    end)
  end

  defp normalize_idempotency_entry(handoff_id, entry) when is_map(entry) do
    handoff_id = safe_text(handoff_id)
    head_sha = string_value(entry, :head_sha)
    handoff_key = string_value(entry, :handoff_key)

    if is_binary(handoff_id) and Receipt.valid_sha?(head_sha) and
         handoff_key == Receipt.idempotency_key(handoff_id, head_sha) do
      %{
        handoff_id: handoff_id,
        fingerprint: value(entry, :fingerprint),
        head_sha: head_sha,
        handoff_key: handoff_key,
        receipt: value(entry, :receipt)
      }
    end
  end

  defp normalize_idempotency_entry(_handoff_id, _entry), do: nil

  defp decode_idempotency(entries) when is_map(entries) do
    entries
    |> Enum.reduce(%{}, fn {handoff_id, entry}, acc ->
      case decode_idempotency_entry(handoff_id, entry) do
        nil -> acc
        normalized -> Map.put(acc, normalized.handoff_id, normalized)
      end
    end)
  end

  defp decode_idempotency(_entries), do: %{}

  defp decode_idempotency_entry(handoff_id, entry) when is_map(entry) do
    normalize_idempotency_entry(
      handoff_id,
      %{
        "fingerprint" => decode_fingerprint(Map.get(entry, "fingerprint")),
        "head_sha" => Map.get(entry, "head_sha"),
        "handoff_key" => Map.get(entry, "handoff_key"),
        "receipt" => decode_receipt(Map.get(entry, "receipt"))
      }
    )
  end

  defp decode_idempotency_entry(_handoff_id, _entry), do: nil

  defp encode_fingerprint(value) when is_binary(value), do: Base.encode16(value, case: :lower)
  defp encode_fingerprint(_value), do: nil

  defp decode_fingerprint(value) when is_binary(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, binary} -> binary
      :error -> nil
    end
  end

  defp decode_fingerprint(_value), do: nil

  defp encode_receipt(receipt) when is_map(receipt) do
    if Receipt.valid_public?(receipt), do: stringify_keys(Receipt.public(receipt))
  end

  defp encode_receipt(_receipt), do: nil

  defp decode_receipt(receipt) when is_map(receipt), do: restore_receipt(receipt)
  defp decode_receipt(_receipt), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp restore_receipt(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {receipt_key(key), restore_receipt(value)} end)
    |> Map.new()
  end

  defp restore_receipt(list) when is_list(list), do: Enum.map(list, &restore_receipt/1)
  defp restore_receipt(value), do: value

  defp receipt_key(key)
       when key in ~w(schema_version contract receipt_id request_id source handoff_id workspace_id runtime_id worker_id session_id workcell_id task_id lease_id correlation_id evidence_ref authorization files git idempotency owner_ref tests),
       do: String.to_existing_atom(key)

  defp receipt_key(key) when key in ~w(name version), do: String.to_existing_atom(key)

  defp receipt_key(key) when key in ~w(provider id role decision decision_id handoff_key),
    do: String.to_existing_atom(key)

  defp receipt_key(key)
       when key in ~w(repository base_branch head_branch head_sha release_sha pr_number pr_url outcome merged_sha merge_actor_ref post_merge_evidence_ref),
       do: String.to_existing_atom(key)

  defp receipt_key(key) when key in ~w(command status path), do: String.to_existing_atom(key)
  defp receipt_key(key), do: key

  defp normalize_health(health) when is_map(health) do
    %{
      ready?: boolean_value(health, :ready?, health_value(health, "ready?", false)),
      healthy?: boolean_value(health, :healthy?, health_value(health, "healthy?", false)),
      readiness: state_value(health, :readiness, nil, :stopped),
      active_worker_count:
        non_negative_integer(
          value(health, :active_worker_count),
          non_negative_integer(Map.get(health, "active_worker_count"), 0)
        ),
      lease_count:
        non_negative_integer(
          value(health, :lease_count),
          non_negative_integer(Map.get(health, "lease_count"), 0)
        ),
      observed_at:
        datetime_value(value(health, :observed_at)) ||
          decode_datetime(Map.get(health, "observed_at"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp encode_health(health) when is_map(health) do
    %{
      "ready?" => boolean_value(health, :ready?, health_value(health, "ready?", false)),
      "healthy?" => boolean_value(health, :healthy?, health_value(health, "healthy?", false)),
      "readiness" => state_string(health, :readiness, nil, :stopped),
      "active_worker_count" => non_negative_integer(value(health, :active_worker_count), 0),
      "lease_count" => non_negative_integer(value(health, :lease_count), 0),
      "observed_at" => encode_datetime(value(health, :observed_at))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decode_health(health) when is_map(health), do: normalize_health(health)
  defp decode_health(_health), do: %{}

  defp normalize_recovery(recovery) when is_map(recovery) do
    %{
      status: state_value(recovery, :status, "status", nil),
      reason: safe_text(value(recovery, :reason) || Map.get(recovery, "reason")),
      recovered_at:
        datetime_value(value(recovery, :recovered_at)) ||
          decode_datetime(Map.get(recovery, "recovered_at")),
      stale_lease_ids:
        normalize_ids(
          list_value(recovery, :stale_lease_ids) ++
            List.wrap(Map.get(recovery, "stale_lease_ids", []))
        )
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp encode_recovery(recovery) when is_map(recovery) do
    %{
      "status" => state_string(recovery, :status, "status", nil),
      "reason" => safe_text(value(recovery, :reason) || Map.get(recovery, "reason")),
      "recovered_at" =>
        encode_datetime(value(recovery, :recovered_at) || Map.get(recovery, "recovered_at")),
      "stale_lease_ids" =>
        normalize_ids(
          list_value(recovery, :stale_lease_ids) ++
            List.wrap(Map.get(recovery, "stale_lease_ids", []))
        )
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decode_recovery(recovery) when is_map(recovery), do: normalize_recovery(recovery)
  defp decode_recovery(_recovery), do: %{}

  defp required(resource, key) do
    case string_value(resource, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {key, :required}}
    end
  end

  defp preserve(resource, existing, key) do
    new_value = Map.get(resource, key)
    old_value = Map.get(existing, key)

    if is_map(new_value) and map_size(new_value) == 0 and is_map(old_value) and
         map_size(old_value) > 0 do
      Map.put(resource, key, old_value)
    else
      resource
    end
  end

  defp state_value(resource, primary, fallback, default) when is_map(resource) do
    value = value(resource, primary) || if(fallback, do: value(resource, fallback))
    state_atom(value, default)
  end

  defp state_string(resource, primary, fallback, default) do
    resource
    |> state_value(primary, fallback, default)
    |> case do
      nil -> nil
      state -> Atom.to_string(state)
    end
  end

  defp state_atom(value, default) when is_atom(value) do
    if Atom.to_string(value) in @states, do: value, else: default
  end

  defp state_atom(value, default) when is_binary(value) do
    Map.get(@state_atoms, value, default)
  end

  defp state_atom(_value, default), do: default

  defp normalize_ids(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != "" and byte_size(&1) <= 256))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp safe_text(value, default \\ nil)
  defp safe_text(nil, default), do: default

  defp safe_text(value, default) when is_atom(value),
    do: safe_text(Atom.to_string(value), default)

  defp safe_text(value, default) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 1_024 and not String.contains?(value, <<0>>),
      do: value,
      else: default
  end

  defp safe_text(_value, default), do: default

  defp string_value(map, key) when is_map(map), do: safe_text(value(map, key))

  defp string_value(_map, _key), do: nil

  defp value(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil when is_atom(key) -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp value(_map, _key), do: nil

  defp list_value(map, key) when is_map(map) do
    case value(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp map_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp boolean_value(map, key, default) do
    case value(map, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp health_value(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp datetime_value(%DateTime{} = value), do: value
  defp datetime_value(_value), do: nil

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(_value), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date_time, _offset} -> date_time
      _ -> nil
    end
  end

  defp decode_datetime(_value), do: nil

  defp present?(value), do: is_binary(value) and value != ""

  defp host_id do
    Application.get_env(:casein, :casein_host_id, "local")
    |> safe_text("local")
  end

  defp adapter do
    Application.get_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)
  end
end
