defmodule Casein.AgentSessions.GrokACP do
  @moduledoc """
  Supervised ACP observer for a Grok leader session.

  The process performs ACP initialization, authenticates with the method Grok
  advertises, then creates or loads a session. Loading the same Grok session as
  a TUI makes this client a leader subscriber, so structured tool, plan, and
  permission events can be projected into `Casein.Agents.Activity` without
  scraping terminal output.

  Permission requests are deliberately left pending until an operator calls
  `respond_permission/3` or `cancel_permission/2`; the leader broadcasts these
  requests to every subscriber and the first response wins.
  """

  use GenServer

  require Logger

  alias Casein.Agents.{Activity, AgentEvents}
  alias Casein.AgentSessions.GrokACP.Protocol
  alias Casein.AgentSessions.GrokACP.Transport.Stdio

  @protocol_version 1

  @type attachment_key :: String.t()

  def child_spec({workspace_id, _cwd, opts} = args) do
    %{
      id: {__MODULE__, workspace_id, attachment_key(opts)},
      start: {__MODULE__, :start_link, [args]},
      restart: :transient
    }
  end

  def start_link({workspace_id, cwd, opts}) do
    GenServer.start_link(__MODULE__, {workspace_id, cwd, opts},
      name: via(workspace_id, attachment_key(opts))
    )
  end

  @doc "Starts one supervised Grok ACP attachment, or returns the existing process."
  @spec ensure_started(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(workspace_id, cwd, opts \\ [])
      when is_binary(workspace_id) and is_binary(cwd) and is_list(opts) do
    case DynamicSupervisor.start_child(
           Casein.Agents.Supervisor,
           {__MODULE__, {workspace_id, cwd, opts}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Looks up a Grok ACP attachment by workspace and attachment key."
  @spec whereis(String.t(), attachment_key()) :: {:ok, pid()} | :error
  def whereis(workspace_id, key \\ "default") do
    case Registry.lookup(Casein.Agents.Registry, registry_key(workspace_id, key)) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Returns negotiated capabilities, session identity, and pending approvals."
  def status(server), do: GenServer.call(server, :status)

  @doc "Loads an existing Grok session, subscribing this client to leader events."
  def attach(server, session_id) when is_binary(session_id) and session_id != "" do
    GenServer.call(server, {:attach, session_id})
  end

  @doc "Replies to a pending permission request with one of Grok's advertised option IDs."
  def respond_permission(server, request_id, option_id)
      when is_binary(option_id) and option_id != "" do
    GenServer.call(server, {:respond_permission, request_id, option_id})
  end

  @doc "Cancels a pending permission request without granting a tool capability."
  def cancel_permission(server, request_id) do
    GenServer.call(server, {:cancel_permission, request_id})
  end

  @doc "Stops this ACP attachment. The shared Grok leader remains available to the TUI."
  def stop(server), do: GenServer.stop(server, :normal)

  def via(workspace_id, key) do
    {:via, Registry, {Casein.Agents.Registry, registry_key(workspace_id, key)}}
  end

  @impl true
  def init({workspace_id, cwd, opts}) do
    transport = Keyword.get(opts, :transport, Stdio)
    transport_opts = Keyword.put(opts, :cwd, cwd)

    with :ok <- validate_start(workspace_id, cwd),
         {:ok, handle} <- transport.start(self(), transport_opts) do
      state = %{
        workspace_id: workspace_id,
        cwd: cwd,
        attachment_key: attachment_key(opts),
        requested_session_id: Keyword.get(opts, :session_id),
        session_id: nil,
        phase: :starting,
        capabilities: %{},
        protocol_version: nil,
        auth_method_id: Keyword.get(opts, :auth_method_id),
        plugin_dirs: Keyword.get(opts, :plugin_dirs, []),
        transport: transport,
        transport_handle: handle,
        buffer: "",
        next_request_id: 1,
        pending_requests: %{},
        pending_permissions: %{},
        status_listener: Keyword.get(opts, :status_listener),
        last_error: nil
      }

      case send_initialize(state) do
        {:ok, state} ->
          notify_status(state)
          {:ok, state}

        {:error, reason, state} ->
          {:stop, reason, state}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:attach, session_id}, _from, state) do
    state = %{state | requested_session_id: session_id}

    case state.phase do
      :ready ->
        case send_session_request(state) do
          {:ok, state} ->
            notify_status(state)
            {:reply, :ok, state}

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end

      phase when phase in [:starting, :initializing, :authenticating] ->
        {:reply, :ok, state}

      :loading_session ->
        {:reply, {:error, :session_attach_in_progress}, state}

      :error ->
        {:reply, {:error, :client_not_ready}, state}
    end
  end

  def handle_call({:respond_permission, request_id, option_id}, _from, state) do
    case Map.fetch(state.pending_permissions, request_id) do
      {:ok, params} ->
        option_ids = permission_option_ids(params)

        if option_id in option_ids do
          payload = %{outcome: %{outcome: "selected", optionId: option_id}}

          case write(state, Protocol.result(request_id, payload)) do
            :ok ->
              record_permission_decision(state, request_id, params, "selected", option_id)

              state = %{
                state
                | pending_permissions: Map.delete(state.pending_permissions, request_id)
              }

              notify_status(state)
              {:reply, :ok, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:reply, {:error, :unknown_permission_option}, state}
        end

      :error ->
        {:reply, {:error, :permission_not_found}, state}
    end
  end

  def handle_call({:cancel_permission, request_id}, _from, state) do
    if Map.has_key?(state.pending_permissions, request_id) do
      payload = %{outcome: %{outcome: "cancelled"}}

      case write(state, Protocol.result(request_id, payload)) do
        :ok ->
          params = Map.fetch!(state.pending_permissions, request_id)
          record_permission_decision(state, request_id, params, "cancelled", nil)

          state = %{
            state
            | pending_permissions: Map.delete(state.pending_permissions, request_id)
          }

          notify_status(state)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :permission_not_found}, state}
    end
  end

  @impl true
  def handle_info({:grok_acp_transport, :stdout, data}, state) when is_binary(data) do
    {messages, buffer} = Protocol.feed(state.buffer, data)
    state = Enum.reduce(messages, %{state | buffer: buffer}, &handle_decoded/2)
    notify_status(state)
    {:noreply, state}
  end

  def handle_info({:grok_acp_transport, :stderr, role, data}, state) do
    Logger.debug("Grok ACP #{role} stderr (#{IO.iodata_length(data)} bytes)")
    {:noreply, state}
  end

  def handle_info({:grok_acp_transport, :exit, reason}, state) do
    {:stop, {:transport_exit, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state[:transport_handle], do: state.transport.stop(state.transport_handle)
    :ok
  end

  defp send_initialize(state) do
    client_version = app_version()

    params = %{
      protocolVersion: @protocol_version,
      clientCapabilities: %{
        fs: %{readTextFile: false, writeTextFile: false},
        terminal: false
      },
      clientInfo: %{name: "devide", title: "Casein", version: client_version},
      _meta: %{
        startupHints: %{
          nonInteractive: true,
          skipGitStatus: true,
          skipProjectLayout: true
        },
        clientType: "devide",
        clientVersion: client_version
      }
    }

    send_request(state, "initialize", params, :initialize, :initializing)
  end

  defp send_authenticate(state, method_id) do
    params = %{methodId: method_id, _meta: %{headless: true}}
    send_request(state, "authenticate", params, :authenticate, :authenticating)
  end

  defp send_session_request(state) do
    with :ok <- ensure_load_supported(state) do
      {method, pending, base_params} =
        case state.requested_session_id do
          session_id when is_binary(session_id) and session_id != "" ->
            {"session/load", {:session, :load}, %{sessionId: session_id}}

          _ ->
            {"session/new", {:session, :new}, %{}}
        end

      params =
        base_params
        |> Map.merge(%{cwd: state.cwd, mcpServers: []})
        |> maybe_put_plugin_dirs(state)

      send_request(state, method, params, pending, :loading_session)
    else
      {:error, reason} -> {:error, reason, put_error(state, reason)}
    end
  end

  defp send_request(state, method, params, pending, phase) do
    id = state.next_request_id

    case write(state, Protocol.request(id, method, params)) do
      :ok ->
        {:ok,
         %{
           state
           | next_request_id: id + 1,
             pending_requests: Map.put(state.pending_requests, id, pending),
             phase: phase,
             last_error: nil
         }}

      {:error, reason} ->
        {:error, reason, put_error(state, reason)}
    end
  end

  defp handle_decoded({:ok, message}, state),
    do: handle_protocol(Protocol.classify(message), state)

  defp handle_decoded({:error, reason}, state) do
    Logger.warning("Discarded malformed Grok ACP stdout frame", reason: inspect(reason))
    state
  end

  defp handle_protocol({:response, id, response}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _pending} ->
        state

      {kind, pending_requests} ->
        state = %{state | pending_requests: pending_requests}
        handle_response(kind, response, state)
    end
  end

  defp handle_protocol({:activity, event, identity}, state) do
    session_id = identity.session_id || state.session_id || state.requested_session_id
    attrs = Protocol.activity_attrs(state.workspace_id, event, session_id)
    record_runtime_activity(attrs, state, identity)
    state
  end

  defp handle_protocol({:permission_request, request_id, params}, state) do
    session_id = Map.get(params, "sessionId") || state.session_id || state.requested_session_id

    attrs =
      Protocol.activity_attrs(
        state.workspace_id,
        {:permission_request, request_id, params},
        session_id
      )

    identity = %{
      session_id: session_id,
      source_event_id: permission_source_event_id(params, request_id),
      source_sequence: nil
    }

    record_runtime_activity(attrs, state, identity)

    %{state | pending_permissions: Map.put(state.pending_permissions, request_id, params)}
  end

  defp handle_protocol({:interaction_resolved, tool_call_id}, state) do
    pending_permissions =
      Map.reject(state.pending_permissions, fn {_request_id, params} ->
        get_in(params, ["toolCall", "toolCallId"]) == tool_call_id
      end)

    %{state | pending_permissions: pending_permissions}
  end

  defp handle_protocol({:unsupported_request, id, method, _params}, state) do
    # We advertise no client filesystem or terminal support. A future Grok
    # capability must be negotiated and implemented before it is accepted.
    _ = write(state, Protocol.error(id, -32_601, "Casein does not support #{method}"))
    state
  end

  defp handle_protocol(:ignore, state), do: state

  defp handle_response(:initialize, {:ok, result}, state) when is_map(result) do
    protocol_version = Map.get(result, "protocolVersion")

    if supported_protocol?(protocol_version) do
      capabilities = result
      auth_method_id = state.auth_method_id || get_in(result, ["_meta", "defaultAuthMethodId"])
      state = %{state | capabilities: capabilities, protocol_version: protocol_version}

      transition_after_initialize(state, auth_method_id)
    else
      put_error(state, {:unsupported_protocol_version, protocol_version})
    end
  end

  defp handle_response(:initialize, {:error, error}, state),
    do: put_rpc_error(state, :initialize_failed, error)

  defp handle_response(:authenticate, {:ok, _result}, state) do
    case send_session_request(state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp handle_response(:authenticate, {:error, error}, state),
    do: put_rpc_error(state, :authentication_required, error)

  defp handle_response({:session, mode}, {:ok, result}, state) when is_map(result) do
    session_id =
      Map.get(result, "sessionId") ||
        if(mode == :load, do: state.requested_session_id, else: nil)

    if is_binary(session_id) and session_id != "" do
      %{state | phase: :ready, session_id: session_id, requested_session_id: session_id}
    else
      put_error(state, :missing_session_id)
    end
  end

  defp handle_response({:session, _mode}, {:error, error}, state),
    do: put_rpc_error(state, :session_attach_failed, error)

  defp transition_after_initialize(state, method_id)
       when is_binary(method_id) and method_id != "" do
    case send_authenticate(state, method_id) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp transition_after_initialize(state, _method_id) do
    case send_session_request(state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp maybe_put_plugin_dirs(params, %{plugin_dirs: []}), do: params

  defp maybe_put_plugin_dirs(params, state) do
    if get_in(state.capabilities, ["_meta", "x.ai/pluginDirs"]) == true do
      Map.put(params, :_meta, %{pluginDirs: state.plugin_dirs})
    else
      params
    end
  end

  defp ensure_load_supported(%{requested_session_id: session_id, capabilities: capabilities})
       when is_binary(session_id) and session_id != "" do
    if get_in(capabilities, ["agentCapabilities", "loadSession"]) == true do
      :ok
    else
      {:error, :load_session_not_supported}
    end
  end

  defp ensure_load_supported(_state), do: :ok

  defp supported_protocol?(version), do: to_string(version) == to_string(@protocol_version)

  defp permission_option_ids(params) do
    params
    |> Map.get("options", [])
    |> Enum.map(&Map.get(&1, "optionId"))
    |> Enum.filter(&is_binary/1)
  end

  defp snapshot(state) do
    %{
      status: state.phase,
      workspace_id: state.workspace_id,
      cwd: state.cwd,
      attachment_key: state.attachment_key,
      session_id: state.session_id || state.requested_session_id,
      protocol_version: state.protocol_version,
      capabilities: state.capabilities,
      pending_permissions:
        state.pending_permissions
        |> Enum.map(fn {request_id, params} ->
          Protocol.permission_summary(request_id, params)
        end)
        |> Enum.sort_by(&to_string(&1.request_id)),
      last_error: state.last_error
    }
  end

  defp notify_status(%{status_listener: listener} = state) when is_pid(listener) do
    send(listener, {:grok_acp_status, self(), snapshot(state)})
    :ok
  end

  defp notify_status(_state), do: :ok

  defp put_rpc_error(state, kind, error) do
    detail = %{
      kind: kind,
      code: Map.get(error, "code"),
      message: error |> Map.get("message", "unknown error") |> truncate_error()
    }

    %{state | phase: :error, last_error: detail}
  end

  defp put_error(state, reason), do: %{state | phase: :error, last_error: reason}

  defp truncate_error(message) when is_binary(message) do
    if String.length(message) > 240, do: String.slice(message, 0, 237) <> "…", else: message
  end

  defp truncate_error(_message), do: "unknown error"

  defp write(state, payload), do: state.transport.write(state.transport_handle, payload)

  defp record_runtime_activity(attrs, state, identity) do
    metadata = attrs.metadata

    event_attrs = %{
      workspace_id: state.workspace_id,
      producer: "grok",
      ingress: "acp",
      source_event_id: identity.source_event_id,
      source_sequence: identity.source_sequence,
      event_type: runtime_event_type(metadata),
      agent_session_id: identity.session_id,
      status: Map.get(metadata, :status) || attrs.status,
      summary: attrs.summary,
      payload: Map.put(metadata, :schema_version, 1)
    }

    case AgentEvents.append_runtime(event_attrs) do
      {:ok, event, :inserted} ->
        record_activity(Map.merge(attrs, %{id: event.id, inserted_at: event.occurred_at}))

      _result ->
        :ok
    end
  end

  defp record_permission_decision(state, request_id, params, outcome, option_id) do
    session_id = Map.get(params, "sessionId") || state.session_id || state.requested_session_id
    tool_call = Map.get(params, "toolCall", %{})

    attrs = %{
      workspace_id: state.workspace_id,
      producer: "grok",
      ingress: "acp",
      source_event_id: "permission-decision:#{request_id}:#{outcome}:#{option_id}",
      event_type: "permission.decided",
      agent_session_id: session_id,
      status: outcome,
      summary: "Permission decision · #{outcome}",
      payload: %{
        schema_version: 1,
        request_id: to_string(request_id),
        tool_call_id: Map.get(tool_call, "toolCallId") || Map.get(tool_call, "tool_call_id"),
        outcome: outcome,
        option_id: option_id
      }
    }

    case AgentEvents.append_runtime(attrs) do
      {:ok, event, :inserted} ->
        record_activity(%{
          id: event.id,
          workspace_id: state.workspace_id,
          source: :grok_acp,
          tool: "grok_permission_decision",
          summary: event.summary,
          status: :ok,
          inserted_at: event.occurred_at,
          metadata: %{
            event: "permission_decision",
            session_id: session_id,
            request_id: to_string(request_id),
            outcome: outcome,
            option_id: option_id
          }
        })

      _result ->
        :ok
    end
  end

  defp runtime_event_type(%{event: "tool_call"}), do: "tool.started"

  defp runtime_event_type(%{event: "tool_call_update", status: status})
       when status in ["completed", "complete"],
       do: "tool.completed"

  defp runtime_event_type(%{event: "tool_call_update", status: status})
       when status in ["failed", "error"],
       do: "tool.failed"

  defp runtime_event_type(%{event: "tool_call_update"}), do: "tool.updated"
  defp runtime_event_type(%{event: "plan"}), do: "plan.updated"
  defp runtime_event_type(%{event: "permission_request"}), do: "permission.requested"
  defp runtime_event_type(_metadata), do: "agent.activity"

  defp permission_source_event_id(params, request_id) do
    get_in(params, ["_meta", "eventId"]) || "permission-request:#{request_id}"
  end

  defp record_activity(attrs) do
    _ = Activity.record(attrs)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp validate_start(workspace_id, cwd) do
    cond do
      workspace_id == "" -> {:error, :invalid_workspace_id}
      cwd == "" or not File.dir?(cwd) -> {:error, :invalid_cwd}
      true -> :ok
    end
  end

  defp attachment_key(opts) do
    case Keyword.get(opts, :attachment_key) || Keyword.get(opts, :session_id) do
      key when is_binary(key) and key != "" -> key
      _ -> "default"
    end
  end

  defp registry_key(workspace_id, key), do: {:grok_acp, workspace_id, key}

  defp app_version do
    case Application.spec(:dev_ide, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end
end
