defmodule DevIDE.Runtimes do
  @moduledoc """
  Runtime orchestration registry for workspace execution environments.

  Runtimes are placement records only. They describe where an already-approved
  safe action should run: host, repo, branch, worktree path, tmux binding, and
  lifecycle state. This module never accepts argv, shells, HTTP proxy targets,
  or new mutation commands.
  """

  alias DevIDE.Files.PathSafety
  alias DevIDE.Runtimes.{Host, LifecycleEvent, Runtime, StateMachine}
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Workspaces.State.WorkspaceRecord

  @default_ttl_seconds 60 * 60
  @runtime_placement_keys ~w(
    runtime_id runtime_path worktree_path repo branch branch_isolation isolation_mode
    host host_id os tools capabilities concurrency_limit tmux_session_id session_id
  )

  @callback upsert_host(Host.t()) :: {:ok, Host.t()} | {:error, term()}
  @callback get_host(String.t()) :: {:ok, Host.t()} | :error
  @callback list_hosts() :: [Host.t()]
  @callback create_runtime(Runtime.t(), LifecycleEvent.t()) ::
              {:ok, Runtime.t()} | {:error, term()}
  @callback update_runtime(Runtime.t(), LifecycleEvent.t() | nil) ::
              {:ok, Runtime.t()} | {:error, term()}
  @callback get_runtime(String.t()) :: {:ok, Runtime.t()} | :error
  @callback list_runtimes(map()) :: [Runtime.t()]
  @callback events_for(String.t()) :: [LifecycleEvent.t()]
  @callback clear() :: :ok

  @spec register_host(map()) :: {:ok, Host.t()} | {:error, term()}
  def register_host(attrs) when is_map(attrs) do
    with {:ok, host_id} <- required_string(attrs, "host_id", "id") do
      host = %Host{
        id: host_id,
        os: string_value(attrs, "os"),
        capabilities: string_list(attrs, "capabilities"),
        tools: string_list(attrs, "tools"),
        concurrency_limit: positive_integer(attrs, "concurrency_limit", 1),
        heartbeat_at: datetime_value(attrs, "heartbeat_at") || DateTime.utc_now(),
        metadata: map_value(attrs, "metadata")
      }

      impl().upsert_host(host)
    end
  end

  def register_host(_attrs), do: {:error, :invalid_attrs}

  def get_host(host_id) when is_binary(host_id), do: impl().get_host(host_id)
  def get_host(_), do: :error

  def list_hosts, do: impl().list_hosts()

  @spec request_runtime(String.t(), map()) :: {:ok, Runtime.t()} | {:error, term()}
  def request_runtime(workspace_id, attrs \\ %{})

  def request_runtime(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    now = datetime_value(attrs, "created_at") || DateTime.utc_now()
    runtime_id = string_value(attrs, "runtime_id") || string_value(attrs, "id") || runtime_id()
    host_id = string_value(attrs, "host_id") || string_value(attrs, "host") || "local"
    isolation_mode = isolation_mode(attrs)

    runtime = %Runtime{
      id: runtime_id,
      workspace_id: workspace_id,
      host_id: host_id,
      os: string_value(attrs, "os"),
      repo: string_value(attrs, "repo"),
      branch: string_value(attrs, "branch"),
      worktree_path: string_value(attrs, "worktree_path") || string_value(attrs, "runtime_path"),
      runner_id: string_value(attrs, "runner_id"),
      session_id: string_value(attrs, "session_id"),
      tmux_session_id: string_value(attrs, "tmux_session_id"),
      isolation_mode: isolation_mode,
      status: "requested",
      capabilities: string_list(attrs, "capabilities"),
      tools: string_list(attrs, "tools"),
      concurrency_limit: positive_integer(attrs, "concurrency_limit", 1),
      active_assignments: 0,
      created_at: now,
      heartbeat_at: datetime_value(attrs, "heartbeat_at") || now,
      metadata: map_value(attrs, "metadata")
    }

    event = event(runtime, nil, "runtime_requested", actor_id: string_value(attrs, "actor_id"))
    impl().create_runtime(runtime, event)
  end

  def request_runtime(_workspace_id, _attrs), do: {:error, :invalid_attrs}

  def provision_runtime(runtime_id, attrs \\ %{}) do
    with {:ok, runtime} <- get_runtime(runtime_id),
         {:ok, "provisioned"} <- StateMachine.transition(runtime.status, :provision) do
      now = datetime_value(attrs, "heartbeat_at") || DateTime.utc_now()

      updated = %{
        runtime
        | status: "provisioned",
          worktree_path:
            string_value(attrs, "worktree_path") ||
              string_value(attrs, "runtime_path") ||
              runtime.worktree_path,
          session_id: string_value(attrs, "session_id") || runtime.session_id,
          tmux_session_id: string_value(attrs, "tmux_session_id") || runtime.tmux_session_id,
          heartbeat_at: now,
          metadata: Map.merge(runtime.metadata || %{}, map_value(attrs, "metadata"))
      }

      impl().update_runtime(
        updated,
        event(updated, runtime.status, "runtime_provisioned",
          actor_id: string_value(attrs, "actor_id"),
          metadata: map_value(attrs, "metadata")
        )
      )
    end
  end

  def bind_runtime(runtime_id, attrs \\ %{}) do
    transition_runtime(runtime_id, :bind, "runtime_bound", attrs, fn runtime ->
      %{
        runtime
        | runner_id: string_value(attrs, "runner_id") || runtime.runner_id,
          active_assignments: min(runtime.active_assignments + 1, runtime.concurrency_limit),
          heartbeat_at: datetime_value(attrs, "heartbeat_at") || DateTime.utc_now()
      }
    end)
  end

  def mark_active(runtime_id, attrs \\ %{}) do
    transition_runtime(runtime_id, :activate, "runtime_active", attrs, fn runtime ->
      %{
        runtime
        | runner_id: string_value(attrs, "runner_id") || runtime.runner_id,
          active_assignments: max(runtime.active_assignments, 1),
          heartbeat_at: datetime_value(attrs, "heartbeat_at") || DateTime.utc_now()
      }
    end)
  end

  def mark_idle(runtime_id, attrs \\ %{}) do
    transition_runtime(runtime_id, :idle, "runtime_idle", attrs, fn runtime ->
      %{
        runtime
        | active_assignments: max(runtime.active_assignments - 1, 0),
          runner_id: string_value(attrs, "runner_id") || runtime.runner_id,
          heartbeat_at: datetime_value(attrs, "heartbeat_at") || DateTime.utc_now()
      }
    end)
  end

  def heartbeat(runtime_id, attrs \\ %{}) do
    with {:ok, runtime} <- get_runtime(runtime_id) do
      now = datetime_value(attrs, "heartbeat_at") || DateTime.utc_now()

      updated = %{
        runtime
        | heartbeat_at: now,
          runner_id: string_value(attrs, "runner_id") || runtime.runner_id
      }

      impl().update_runtime(
        updated,
        event(updated, runtime.status, "runtime_heartbeat",
          actor_id: string_value(attrs, "actor_id"),
          assignment_id: string_value(attrs, "assignment_id"),
          runner_id: string_value(attrs, "runner_id")
        )
      )
    end
  end

  def expire_runtime(runtime_id, attrs \\ %{}) do
    transition_runtime(runtime_id, :expire, "runtime_expired", attrs, fn runtime ->
      now = datetime_value(attrs, "expired_at") || DateTime.utc_now()

      %{
        runtime
        | status: "expired",
          expired_at: now,
          failure_reason: string_value(attrs, "reason") || runtime.failure_reason,
          heartbeat_at: runtime.heartbeat_at || now
      }
    end)
  end

  def fail_runtime(runtime_id, attrs \\ %{}) do
    transition_runtime(runtime_id, :fail, "runtime_failed", attrs, fn runtime ->
      %{
        runtime
        | failure_reason: string_value(attrs, "reason") || runtime.failure_reason,
          heartbeat_at: datetime_value(attrs, "heartbeat_at") || runtime.heartbeat_at
      }
    end)
  end

  def cleanup_runtime(runtime_id, attrs \\ %{}) do
    transition_runtime(runtime_id, :cleanup, "runtime_cleaned", attrs, fn runtime ->
      now = datetime_value(attrs, "cleaned_at") || DateTime.utc_now()
      %{runtime | cleaned_at: now, active_assignments: 0}
    end)
  end

  def list_runtimes(filters \\ %{}), do: impl().list_runtimes(normalize_filter(filters))

  def get_runtime(runtime_id) when is_binary(runtime_id), do: impl().get_runtime(runtime_id)
  def get_runtime(_), do: :error

  def events_for(runtime_id) when is_binary(runtime_id), do: impl().events_for(runtime_id)
  def events_for(_), do: []

  def clear, do: impl().clear()

  @doc "Expire runtimes whose heartbeat/creation timestamp is older than their TTL."
  def expire_stale(now \\ DateTime.utc_now(), opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    %{}
    |> list_runtimes()
    |> Enum.filter(&stale?(&1, now, ttl_seconds))
    |> Enum.flat_map(fn runtime ->
      case expire_runtime(runtime.id, %{"reason" => "stale_runtime", "expired_at" => now}) do
        {:ok, expired} -> [expired]
        {:error, _reason} -> []
      end
    end)
  end

  def cleanup_expired(_now \\ DateTime.utc_now(), _opts \\ []) do
    list_runtimes(%{"status" => "expired"})
    |> Enum.flat_map(fn runtime ->
      case cleanup_runtime(runtime.id) do
        {:ok, cleaned} -> [cleaned]
        {:error, _reason} -> []
      end
    end)
  end

  @doc """
  Place an assignment onto a runtime when metadata explicitly requests runtime
  orchestration. The returned metadata is advisory routing only.
  """
  @spec place_assignment(WorkspaceRecord.t(), map()) :: {:ok, map()} | {:error, term()}
  def place_assignment(%WorkspaceRecord{} = record, metadata) when is_map(metadata) do
    if runtime_requested?(metadata) do
      request = placement_request(record, metadata)

      with {:ok, host} <- select_host(request),
           {:ok, runtime} <- select_or_create_runtime(record, request, host),
           {:ok, bound} <- bind_runtime(runtime.id, request) do
        {:ok, put_runtime_metadata(metadata, bound)}
      end
    else
      {:ok, metadata}
    end
  end

  def place_assignment(_record, metadata) when is_map(metadata), do: {:ok, metadata}
  def place_assignment(_record, _metadata), do: {:error, :invalid_runtime_metadata}

  @doc "Add current runtime projection to assignment metadata for read surfaces."
  def decorate_assignment_metadata(metadata) when is_map(metadata) do
    case runtime_id_from_metadata(metadata) do
      nil ->
        metadata

      runtime_id ->
        case get_runtime(runtime_id) do
          {:ok, %Runtime{} = runtime} -> put_runtime_metadata(metadata, runtime)
          :error -> metadata
        end
    end
  end

  def decorate_assignment_metadata(metadata), do: metadata

  def runtime_id_from_metadata(metadata) when is_map(metadata) do
    runtime = Map.get(metadata, "runtime") || Map.get(metadata, :runtime) || %{}

    string_value(runtime, "id") ||
      string_value(runtime, "runtime_id") ||
      string_value(metadata, "runtime_id") ||
      string_value(metadata, "runtime")
  end

  def runtime_id_from_metadata(_), do: nil

  def payload(%Runtime{} = runtime) do
    %{
      id: runtime.id,
      workspace_id: runtime.workspace_id,
      host: runtime.host_id,
      os: runtime.os,
      repo: runtime.repo,
      branch: runtime.branch,
      worktree_path: runtime.worktree_path,
      runner_id: runtime.runner_id,
      session_id: runtime.session_id,
      tmux_session_id: runtime.tmux_session_id,
      isolation_mode: runtime.isolation_mode,
      status: runtime.status,
      capabilities: runtime.capabilities,
      tools: runtime.tools,
      concurrency_limit: runtime.concurrency_limit,
      active_assignments: runtime.active_assignments,
      created_at: iso(runtime.created_at),
      heartbeat_at: iso(runtime.heartbeat_at),
      expired_at: iso(runtime.expired_at),
      cleaned_at: iso(runtime.cleaned_at),
      failure_reason: runtime.failure_reason,
      metadata: runtime.metadata || %{}
    }
  end

  def event_payload(%LifecycleEvent{} = event) do
    %{
      id: event.id,
      runtime_id: event.runtime_id,
      workspace_id: event.workspace_id,
      event: event.event,
      from_status: event.from_status,
      to_status: event.to_status,
      actor_id: event.actor_id,
      assignment_id: event.assignment_id,
      runner_id: event.runner_id,
      metadata: event.metadata || %{},
      inserted_at: iso(event.inserted_at)
    }
  end

  def project_lifecycle(events), do: StateMachine.reduce(events)

  defp transition_runtime(runtime_id, transition, event_name, attrs, updater) do
    with {:ok, runtime} <- get_runtime(runtime_id),
         {:ok, next_status} <- StateMachine.transition(runtime.status, transition) do
      updated =
        runtime
        |> updater.()
        |> Map.put(:status, next_status)

      impl().update_runtime(
        updated,
        event(updated, runtime.status, event_name,
          actor_id: string_value(attrs, "actor_id"),
          assignment_id: string_value(attrs, "assignment_id"),
          runner_id: string_value(attrs, "runner_id"),
          metadata: map_value(attrs, "metadata")
        )
      )
    end
  end

  defp runtime_requested?(metadata) do
    runtime = Map.get(metadata, "runtime") || Map.get(metadata, :runtime)

    is_map(runtime) or
      Enum.any?(@runtime_placement_keys, fn key ->
        present?(Map.get(metadata, key)) or present?(Map.get(metadata, String.to_atom(key)))
      end)
  end

  defp placement_request(%WorkspaceRecord{} = record, metadata) do
    runtime = Map.get(metadata, "runtime") || Map.get(metadata, :runtime) || %{}
    routing = Map.get(metadata, "routing") || Map.get(metadata, :routing) || %{}
    merged = Map.merge(routing, Map.merge(metadata, runtime))

    %{
      "runtime_id" => string_value(merged, "runtime_id") || string_value(merged, "id"),
      "host_id" => string_value(merged, "host_id") || string_value(merged, "host"),
      "os" => string_value(merged, "os"),
      "repo" => string_value(merged, "repo") || infer_repo(record),
      "branch" => string_value(merged, "branch") || infer_branch(record),
      "isolation_mode" => isolation_mode(merged),
      "worktree_path" =>
        string_value(merged, "worktree_path") || string_value(merged, "runtime_path"),
      "tools" => string_list(merged, "tools"),
      "capabilities" => string_list(merged, "capabilities"),
      "concurrency_limit" => positive_integer(merged, "concurrency_limit", 1),
      "tmux_session_id" => string_value(merged, "tmux_session_id"),
      "session_id" => string_value(merged, "session_id"),
      "actor_id" => string_value(metadata, "trigger") || string_value(metadata, "source"),
      "assignment_id" => string_value(metadata, "jx_assignment_id"),
      "metadata" => %{
        "source" => "runtime_orchestration",
        "branch_isolation" => isolation_mode(merged),
        "provisioning_model" => "git_worktree",
        "tmux_binding" => "record_only"
      }
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp select_host(request) do
    hosts = list_hosts()
    matching = Enum.find(hosts, &host_matches?(&1, request))

    cond do
      matching ->
        {:ok, matching}

      hosts == [] ->
        with {:ok, host} <- register_default_host(request),
             true <- host_matches?(host, request) || {:error, :runtime_host_unavailable} do
          {:ok, host}
        end

      true ->
        {:error, :runtime_host_unavailable}
    end
  end

  defp register_default_host(request) do
    register_host(%{
      "host_id" => Map.get(request, "host_id") || "local",
      "os" => current_os(),
      "tools" => Map.get(request, "tools", []),
      "capabilities" => Map.get(request, "capabilities", []),
      "concurrency_limit" => Map.get(request, "concurrency_limit", 1)
    })
  end

  defp host_matches?(%Host{} = host, request) do
    host_active_assignments = host_active_assignments(host.id)
    required_tools = Map.get(request, "tools", [])
    required_capabilities = Map.get(request, "capabilities", [])

    optional_match?(host.id, Map.get(request, "host_id")) and
      optional_match?(host.os, Map.get(request, "os")) and
      contains_all?(host.tools, required_tools) and
      contains_all?(host.capabilities, required_capabilities) and
      host_active_assignments < host.concurrency_limit
  end

  defp select_or_create_runtime(%WorkspaceRecord{} = record, request, %Host{} = host) do
    case find_runtime(record.external_id, request, host) do
      %Runtime{} = runtime ->
        {:ok, runtime}

      nil ->
        create_placed_runtime(record, request, host)
    end
  end

  defp find_runtime(workspace_id, request, %Host{} = host) do
    list_runtimes(%{"workspace_id" => workspace_id})
    |> Enum.filter(&(&1.status in ["provisioned", "idle", "bound", "active"]))
    |> Enum.find(fn runtime ->
      optional_match?(runtime.id, Map.get(request, "runtime_id")) and
        runtime.host_id == host.id and
        optional_match?(runtime.os, Map.get(request, "os")) and
        optional_match?(runtime.repo, Map.get(request, "repo")) and
        optional_match?(runtime.branch, Map.get(request, "branch")) and
        runtime.isolation_mode == Map.get(request, "isolation_mode", "worktree") and
        contains_all?(runtime.tools, Map.get(request, "tools", [])) and
        contains_all?(runtime.capabilities, Map.get(request, "capabilities", [])) and
        runtime.active_assignments < runtime.concurrency_limit
    end)
  end

  defp create_placed_runtime(%WorkspaceRecord{} = record, request, %Host{} = host) do
    runtime_id = Map.get(request, "runtime_id") || runtime_id()

    with {:ok, worktree_path} <- worktree_path(record, request, runtime_id),
         {:ok, requested} <-
           request_runtime(record.external_id, %{
             "runtime_id" => runtime_id,
             "host_id" => host.id,
             "os" => Map.get(request, "os") || host.os,
             "repo" => Map.get(request, "repo"),
             "branch" => Map.get(request, "branch"),
             "worktree_path" => worktree_path,
             "isolation_mode" => Map.get(request, "isolation_mode", "worktree"),
             "tools" => Enum.uniq(host.tools ++ Map.get(request, "tools", [])),
             "capabilities" =>
               Enum.uniq(host.capabilities ++ Map.get(request, "capabilities", [])),
             "concurrency_limit" =>
               min(Map.get(request, "concurrency_limit", 1), host.concurrency_limit),
             "tmux_session_id" =>
               Map.get(request, "tmux_session_id") ||
                 Tmux.session_name(record.name || record.external_id, runtime_id),
             "session_id" => Map.get(request, "session_id"),
             "actor_id" => Map.get(request, "actor_id"),
             "metadata" =>
               Map.merge(Map.get(request, "metadata", %{}), %{
                 "required_tools" => Map.get(request, "tools", []),
                 "required_capabilities" => Map.get(request, "capabilities", [])
               })
           }) do
      provision_runtime(requested.id, %{
        "worktree_path" => worktree_path,
        "tmux_session_id" => requested.tmux_session_id,
        "actor_id" => Map.get(request, "actor_id"),
        "metadata" => %{"provisioning_model" => "git_worktree_record"}
      })
    end
  end

  defp put_runtime_metadata(metadata, %Runtime{} = runtime) do
    routing = Map.get(metadata, "routing") || Map.get(metadata, :routing) || %{}

    runtime_map =
      %{
        "id" => runtime.id,
        "runtime_id" => runtime.id,
        "runtime_path" => runtime.worktree_path,
        "worktree_path" => runtime.worktree_path,
        "host" => runtime.host_id,
        "os" => runtime.os,
        "repo" => runtime.repo,
        "branch" => runtime.branch,
        "branch_isolation" => runtime.isolation_mode,
        "isolation_mode" => runtime.isolation_mode,
        "runner_id" => runtime.runner_id,
        "session_id" => runtime.session_id,
        "tmux_session_id" => runtime.tmux_session_id,
        "status" => runtime.status,
        "active_assignments" => runtime.active_assignments,
        "concurrency_limit" => runtime.concurrency_limit
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new()

    required_tools =
      Map.get(runtime.metadata || %{}, "required_tools") ||
        Map.get(runtime.metadata || %{}, :required_tools) ||
        runtime.tools

    routing =
      routing
      |> Map.merge(%{
        "host" => runtime.host_id,
        "os" => runtime.os,
        "repo" => runtime.repo,
        "branch_isolation" => runtime.isolation_mode,
        "runtime_id" => runtime.id,
        "runtime_path" => runtime.worktree_path,
        "tools" => required_tools
      })
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new()

    metadata
    |> Map.put("runtime", runtime_map)
    |> Map.put("runtime_id", runtime.id)
    |> Map.put("runtime_path", runtime.worktree_path)
    |> Map.put("routing", routing)
  end

  defp event(%Runtime{} = runtime, from_status, event, opts) do
    %LifecycleEvent{
      id: Ecto.UUID.generate(),
      runtime_id: runtime.id,
      workspace_id: runtime.workspace_id,
      event: event,
      from_status: from_status,
      to_status: runtime.status,
      actor_id: Keyword.get(opts, :actor_id),
      assignment_id: Keyword.get(opts, :assignment_id),
      runner_id: Keyword.get(opts, :runner_id),
      metadata: Keyword.get(opts, :metadata, %{}) || %{},
      inserted_at: DateTime.utc_now()
    }
  end

  defp worktree_path(%WorkspaceRecord{host_path: nil}, _request, _runtime_id),
    do: {:error, :workspace_root_unavailable}

  defp worktree_path(%WorkspaceRecord{host_path: root}, request, runtime_id) do
    relative_or_absolute = Map.get(request, "worktree_path") || ".devide/runtimes/#{runtime_id}"
    PathSafety.resolve(root, relative_or_absolute)
  end

  defp host_active_assignments(host_id) do
    list_runtimes(%{"host_id" => host_id})
    |> Enum.filter(&(&1.status in ["bound", "active"]))
    |> Enum.reduce(0, &(&1.active_assignments + &2))
  end

  defp stale?(%Runtime{status: status}, _now, _ttl_seconds)
       when status in ["expired", "failed", "cleaned"],
       do: false

  defp stale?(%Runtime{} = runtime, now, ttl_seconds) do
    last_seen = runtime.heartbeat_at || runtime.created_at
    last_seen && DateTime.compare(DateTime.add(last_seen, ttl_seconds, :second), now) != :gt
  end

  defp infer_branch(%WorkspaceRecord{manager_payload: payload}) do
    string_value(payload || %{}, "branch")
  end

  defp infer_repo(%WorkspaceRecord{manager_payload: payload, host_path: host_path}) do
    string_value(payload || %{}, "repo") ||
      string_value(payload || %{}, "repository") ||
      if(is_binary(host_path), do: Path.basename(host_path))
  end

  defp runtime_id, do: "rt-" <> Ecto.UUID.generate()

  defp isolation_mode(attrs),
    do:
      string_value(attrs, "isolation_mode") || string_value(attrs, "branch_isolation") ||
        "worktree"

  defp normalize_filter(filters) when is_map(filters) do
    filters
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp normalize_filter(_), do: %{}

  defp required_string(attrs, key, fallback_key) do
    case string_value(attrs, key) || string_value(attrs, fallback_key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, String.to_atom("#{key}_required")}
    end
  end

  defp string_value(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp string_value(_, _), do: nil

  defp string_list(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp string_list(_, _), do: []

  defp positive_integer(attrs, key, fallback) when is_map(attrs) do
    value = Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

    parsed =
      cond do
        is_integer(value) -> value
        is_binary(value) -> parse_int(value, fallback)
        true -> fallback
      end

    max(parsed, 1)
  end

  defp positive_integer(_, _, fallback), do: fallback

  defp parse_int(value, fallback) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> fallback
    end
  end

  defp datetime_value(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      %DateTime{} = dt ->
        dt

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp datetime_value(_, _), do: nil

  defp map_value(attrs, key) when is_map(attrs) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp map_value(_, _), do: %{}

  defp optional_match?(_value, nil), do: true
  defp optional_match?(value, required), do: value == required

  defp contains_all?(available, required) when is_list(available) and is_list(required),
    do: Enum.all?(required, &(&1 in available))

  defp contains_all?(_, []), do: true
  defp contains_all?(_, _), do: false

  defp present?(value), do: value not in [nil, "", [], %{}]

  defp current_os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, _} -> "linux"
      {:win32, _} -> "windows"
      _ -> "unknown"
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp impl,
    do:
      Application.get_env(
        :dev_ide,
        :runtime_orchestration_adapter,
        DevIDE.Runtimes.MemoryAdapter
      )
end
