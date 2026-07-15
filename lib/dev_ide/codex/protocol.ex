defmodule DevIDE.Codex.Protocol do
  @moduledoc """
  Normalizes Codex App Server messages into DevIDE-owned contracts.

  No raw App Server message should cross this module into projections, PubSub,
  signals, audit, or UI code.
  """

  alias DevIDE.Codex.{Approval, Event}

  @thread_statuses %{
    "notLoaded" => :not_loaded,
    "idle" => :idle,
    "systemError" => :system_error,
    "active" => :active
  }
  @thread_active_flags %{
    "waitingOnApproval" => :waiting_on_approval,
    "waitingOnUserInput" => :waiting_on_user_input
  }
  @turn_statuses %{
    "completed" => :completed,
    "interrupted" => :interrupted,
    "failed" => :failed,
    "inProgress" => :in_progress
  }
  @session_sources %{
    "cli" => :cli,
    "vscode" => :vscode,
    "exec" => :exec,
    "appServer" => :app_server,
    "unknown" => :unknown
  }
  @approval_methods %{
    "item/commandExecution/requestApproval" => :command_execution,
    "item/fileChange/requestApproval" => :file_change,
    "item/permissions/requestApproval" => :permissions
  }

  @type normalize_error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unknown_thread_status, String.t()}
          | {:unknown_turn_status, String.t()}

  @spec normalize(DevIDE.Codex.JsonRpc.decoded(), map()) ::
          {:ok, Event.t()} | :ignore | {:error, normalize_error()}
  def normalize({:notification, "thread/started", params}, context) do
    with {:ok, thread} <- map_field(params, "thread", "params.thread"),
         {:ok, normalized} <- normalize_thread(thread) do
      {:ok,
       Event.new!(:thread_started, context,
         thread_id: normalized.thread_id,
         parent_thread_id: normalized.parent_thread_id,
         session_id: normalized.session_id,
         payload: normalized.payload,
         metadata: method_metadata("thread/started")
       )}
    end
  end

  def normalize({:notification, "thread/status/changed", params}, context) do
    with {:ok, thread_id} <- string_field(params, "threadId", "params.threadId"),
         {:ok, status_map} <- map_field(params, "status", "params.status"),
         {:ok, status} <- normalize_thread_status(status_map) do
      {:ok,
       Event.new!(:thread_status_changed, context,
         thread_id: thread_id,
         payload: status,
         metadata: method_metadata("thread/status/changed")
       )}
    end
  end

  def normalize({:notification, "turn/started", params}, context) do
    normalize_turn_event(:turn_started, "turn/started", params, context)
  end

  def normalize({:notification, "turn/completed", params}, context) do
    normalize_turn_event(:turn_completed, "turn/completed", params, context)
  end

  def normalize({:notification, "item/agentMessage/delta", params}, context) do
    with {:ok, thread_id} <- string_field(params, "threadId", "params.threadId"),
         {:ok, turn_id} <- string_field(params, "turnId", "params.turnId"),
         {:ok, item_id} <- string_field(params, "itemId", "params.itemId"),
         {:ok, delta} <- binary_field(params, "delta", "params.delta") do
      {:ok,
       Event.new!(:agent_message_delta, context,
         thread_id: thread_id,
         turn_id: turn_id,
         item_id: item_id,
         payload: %{delta: delta},
         metadata: method_metadata("item/agentMessage/delta")
       )}
    end
  end

  def normalize({:notification, _method, _params}, _context), do: :ignore
  def normalize(_message, _context), do: :ignore

  @doc false
  @spec normalize_server_request(DevIDE.Codex.JsonRpc.decoded(), map()) ::
          {:ok, Approval.t()} | :unsupported | {:error, normalize_error()}
  def normalize_server_request({:request, request_id, method, params}, context) do
    case Map.fetch(@approval_methods, method) do
      {:ok, kind} -> normalize_approval(kind, request_id, method, params, context)
      :error -> :unsupported
    end
  end

  def normalize_server_request(_request, _context), do: :unsupported

  @doc false
  @spec normalize_response(:initialize | :thread_start | :thread_resume | :turn_start, term()) ::
          {:ok, map()} | {:error, normalize_error()}
  def normalize_response(:initialize, result) when is_map(result) do
    with {:ok, user_agent} <- string_field(result, "userAgent", "result.userAgent"),
         {:ok, platform_family} <-
           string_field(result, "platformFamily", "result.platformFamily"),
         {:ok, platform_os} <- string_field(result, "platformOs", "result.platformOs") do
      {:ok,
       %{
         user_agent: user_agent,
         platform_family: platform_family,
         platform_os: platform_os
       }}
    end
  end

  def normalize_response(:thread_start, result) when is_map(result) do
    normalize_thread_response(result)
  end

  def normalize_response(:thread_resume, result) when is_map(result) do
    with {:ok, normalized} <- normalize_thread_response(result) do
      {:ok,
       Map.merge(normalized, %{
         cwd: optional_binary(result, "cwd"),
         model: optional_binary(result, "model"),
         model_provider: optional_binary(result, "modelProvider")
       })}
    end
  end

  def normalize_response(:turn_start, result) when is_map(result) do
    with {:ok, turn} <- map_field(result, "turn", "result.turn"),
         {:ok, normalized} <- normalize_turn(turn) do
      {:ok, %{turn_id: normalized.turn_id, turn: normalized.payload}}
    end
  end

  def normalize_response(_kind, _result), do: {:error, {:invalid_field, "result"}}

  defp normalize_thread_response(result) do
    with {:ok, thread} <- map_field(result, "thread", "result.thread"),
         {:ok, normalized} <- normalize_thread(thread) do
      {:ok,
       %{
         thread_id: normalized.thread_id,
         parent_thread_id: normalized.parent_thread_id,
         session_id: normalized.session_id,
         thread: normalized.payload
       }}
    end
  end

  defp normalize_approval(kind, request_id, method, params, context) do
    with {:ok, thread_id} <- string_field(params, "threadId", "params.threadId"),
         {:ok, turn_id} <- string_field(params, "turnId", "params.turnId"),
         {:ok, item_id} <- string_field(params, "itemId", "params.itemId"),
         {:ok, started_at_ms} <- integer_field(params, "startedAtMs", "params.startedAtMs") do
      requested_at =
        unix_datetime(started_at_ms, :millisecond) ||
          Map.get(context, :occurred_at, DateTime.utc_now())

      {:ok,
       %Approval{
         id: Ecto.UUID.generate(),
         kind: kind,
         workspace_id: Map.fetch!(context, :workspace_id),
         runtime_id: Map.fetch!(context, :runtime_id),
         request_id: request_id,
         thread_id: thread_id,
         turn_id: turn_id,
         item_id: item_id,
         approval_id: optional_binary(params, "approvalId"),
         requested_at: requested_at,
         payload: approval_payload(kind, params),
         metadata: method_metadata(method)
       }}
    end
  end

  defp approval_payload(:command_execution, params) do
    %{
      command: optional_binary(params, "command"),
      command_actions: optional_list(params, "commandActions"),
      cwd: optional_binary(params, "cwd"),
      reason: optional_binary(params, "reason"),
      proposed_execpolicy_amendment: optional_list(params, "proposedExecpolicyAmendment"),
      proposed_network_policy_amendments: optional_list(params, "proposedNetworkPolicyAmendments")
    }
    |> compact()
  end

  defp approval_payload(:file_change, params) do
    %{
      grant_root: optional_binary(params, "grantRoot"),
      reason: optional_binary(params, "reason")
    }
    |> compact()
  end

  defp approval_payload(:permissions, params) do
    %{
      cwd: optional_binary(params, "cwd"),
      permissions: optional_map(params, "permissions"),
      reason: optional_binary(params, "reason")
    }
    |> compact()
  end

  defp normalize_turn_event(type, method, params, context) do
    with {:ok, thread_id} <- string_field(params, "threadId", "params.threadId"),
         {:ok, turn} <- map_field(params, "turn", "params.turn"),
         {:ok, normalized} <- normalize_turn(turn) do
      {:ok,
       Event.new!(type, context,
         thread_id: thread_id,
         turn_id: normalized.turn_id,
         payload: normalized.payload,
         metadata: method_metadata(method)
       )}
    end
  end

  defp normalize_thread(thread) do
    with {:ok, thread_id} <- string_field(thread, "id", "thread.id"),
         {:ok, status_map} <- map_field(thread, "status", "thread.status"),
         {:ok, status} <- normalize_thread_status(status_map) do
      payload =
        status
        |> Map.merge(%{
          cwd: optional_binary(thread, "cwd"),
          ephemeral: optional_boolean(thread, "ephemeral"),
          preview: optional_binary(thread, "preview"),
          model_provider: optional_binary(thread, "modelProvider"),
          cli_version: optional_binary(thread, "cliVersion"),
          agent_role: optional_binary(thread, "agentRole"),
          agent_nickname: optional_binary(thread, "agentNickname"),
          source: normalize_session_source(Map.get(thread, "source")),
          created_at: unix_datetime(Map.get(thread, "createdAt"), :second),
          updated_at: unix_datetime(Map.get(thread, "updatedAt"), :second)
        })
        |> compact()

      {:ok,
       %{
         thread_id: thread_id,
         parent_thread_id: optional_binary(thread, "parentThreadId"),
         session_id: optional_binary(thread, "sessionId"),
         payload: payload
       }}
    end
  end

  defp normalize_turn(turn) do
    with {:ok, turn_id} <- string_field(turn, "id", "turn.id"),
         {:ok, status} <- normalize_turn_status(Map.get(turn, "status")) do
      payload =
        %{
          status: status,
          started_at: unix_datetime(Map.get(turn, "startedAt"), :second),
          completed_at: unix_datetime(Map.get(turn, "completedAt"), :second),
          duration_ms: optional_integer(turn, "durationMs"),
          item_count: list_count(turn, "items"),
          error: normalize_turn_error(Map.get(turn, "error"))
        }
        |> compact()

      {:ok, %{turn_id: turn_id, payload: payload}}
    end
  end

  defp normalize_thread_status(%{"type" => type} = status) when is_binary(type) do
    case Map.fetch(@thread_statuses, type) do
      {:ok, normalized} ->
        flags =
          status
          |> Map.get("activeFlags", [])
          |> normalize_active_flags()

        {:ok, %{status: normalized, active_flags: flags}}

      :error ->
        {:error, {:unknown_thread_status, type}}
    end
  end

  defp normalize_thread_status(_status), do: {:error, {:invalid_field, "status.type"}}

  defp normalize_active_flags(flags) when is_list(flags) do
    flags
    |> Enum.map(&Map.get(@thread_active_flags, &1, :unknown))
    |> Enum.uniq()
  end

  defp normalize_active_flags(_flags), do: []

  defp normalize_turn_status(status) when is_binary(status) do
    case Map.fetch(@turn_statuses, status) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:unknown_turn_status, status}}
    end
  end

  defp normalize_turn_status(_status), do: {:error, {:invalid_field, "turn.status"}}

  defp normalize_session_source(source) when is_binary(source),
    do: Map.get(@session_sources, source, :unknown)

  defp normalize_session_source(%{"subAgent" => _source}), do: :subagent
  defp normalize_session_source(%{"custom" => _source}), do: :custom
  defp normalize_session_source(_source), do: nil

  defp normalize_turn_error(%{"message" => message} = error) when is_binary(message) do
    compact(%{message: message, details: optional_binary(error, "additionalDetails")})
  end

  defp normalize_turn_error(_error), do: nil

  defp method_metadata(method), do: %{codex_method: method}

  defp string_field(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, path}}
      :error -> {:error, {:missing_field, path}}
    end
  end

  defp binary_field(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, path}}
      :error -> {:error, {:missing_field, path}}
    end
  end

  defp map_field(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, path}}
      :error -> {:error, {:missing_field, path}}
    end
  end

  defp integer_field(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, path}}
      :error -> {:error, {:missing_field, path}}
    end
  end

  defp optional_binary(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp optional_boolean(map, key) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      _other -> nil
    end
  end

  defp optional_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp optional_list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      _other -> nil
    end
  end

  defp optional_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  defp list_count(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> length(value)
      _other -> nil
    end
  end

  defp unix_datetime(value, unit) when is_integer(value) do
    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp unix_datetime(_value, _unit), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
