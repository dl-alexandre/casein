defmodule Casein.Codex.AppServer do
  @moduledoc """
  Supervised owner of one Codex App Server stdio process.

  The process performs the mandatory initialize/initialized handshake, tracks
  JSON-RPC requests, and emits only canonical `Casein.Codex.Event` structs to
  subscribers. Raw App Server maps remain inside the Codex boundary.
  """

  use GenServer

  alias Casein.Codex.{ApprovalBroker, EventRouter, JsonRpc, Protocol}

  @default_request_timeout 30_000
  @default_initialize_timeout 10_000
  @max_line_bytes 10_000_000
  @max_buffer_bytes 20_000_000
  @sensitive_shell_env [
    "DEV_IDE_API_TOKEN",
    "DEV_IDE_ADMIN_API_TOKEN",
    "DEV_IDE_WORKSPACE_API_TOKENS"
  ]

  @type status :: :initializing | :ready
  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts) do
    runtime_id = Keyword.fetch!(opts, :runtime_id)

    %{
      id: {__MODULE__, runtime_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Wait until the App Server initialize handshake has completed."
  @spec await_ready(server(), timeout()) :: :ok | {:error, term()}
  def await_ready(server, timeout \\ @default_initialize_timeout) do
    GenServer.call(server, {:await_ready, timeout}, timeout + 1_000)
  end

  @doc "Return the canonical runtime status and identity."
  @spec status(server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @doc "Subscribe a process to canonical events and runtime status changes."
  @spec subscribe(server(), pid()) :: :ok
  def subscribe(server, subscriber \\ self()) when is_pid(subscriber) do
    GenServer.call(server, {:subscribe, subscriber})
  end

  @doc "Start a Codex thread in this runtime's working directory."
  @spec start_thread(server(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def start_thread(server, params \\ %{}, timeout \\ @default_request_timeout)
      when is_map(params) do
    GenServer.call(server, {:start_thread, params, timeout}, timeout + 1_000)
  end

  @doc "Resume a durable Codex thread after this App Server process restarts."
  @spec resume_thread(server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def resume_thread(server, thread_id, params \\ %{}, timeout \\ @default_request_timeout)
      when is_binary(thread_id) and thread_id != "" and is_map(params) do
    GenServer.call(server, {:resume_thread, thread_id, params, timeout}, timeout + 1_000)
  end

  @doc "Start a turn with text or already-shaped App Server user input entries."
  @spec start_turn(server(), String.t(), String.t() | [map()], map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def start_turn(
        server,
        thread_id,
        input,
        params \\ %{},
        timeout \\ @default_request_timeout
      )
      when is_binary(thread_id) and thread_id != "" and is_map(params) do
    with {:ok, normalized_input} <- normalize_input(input) do
      GenServer.call(
        server,
        {:start_turn, thread_id, normalized_input, params, timeout},
        timeout + 1_000
      )
    end
  end

  @doc false
  @spec reply_server_request(server(), JsonRpc.request_id(), map(), timeout()) ::
          :ok | {:error, term()}
  def reply_server_request(server, request_id, result, timeout \\ @default_request_timeout)
      when is_map(result) do
    GenServer.call(server, {:reply_server_request, request_id, result}, timeout)
  end

  @impl true
  def init(opts) do
    with {:ok, workspace_id} <- required_string(opts, :workspace_id),
         {:ok, runtime_id} <- required_string(opts, :runtime_id),
         {:ok, cwd} <- valid_cwd(opts),
         {:ok, executable} <- executable(opts),
         {:ok, security} <- security_defaults(opts),
         {:ok, port} <- open_port(executable, port_args(opts), cwd, Keyword.get(opts, :env, [])) do
      state = %{
        workspace_id: workspace_id,
        runtime_id: runtime_id,
        cwd: cwd,
        security: security,
        port: port,
        status: :initializing,
        runtime_metadata: %{},
        request_id: 0,
        pending: %{},
        ready_waiters: %{},
        subscribers: %{},
        event_router: Keyword.get(opts, :event_router),
        approval_broker: Keyword.get(opts, :approval_broker),
        line_buffer: "",
        sequence: 0,
        request_timeout: Keyword.get(opts, :request_timeout, @default_request_timeout),
        initialize_timeout: Keyword.get(opts, :initialize_timeout, @default_initialize_timeout)
      }

      state =
        opts
        |> Keyword.get(:subscriber)
        |> List.wrap()
        |> Enum.filter(&is_pid/1)
        |> Enum.reduce(state, &put_subscriber(&2, &1))

      state = send_initialize(state, Keyword.get(opts, :client_info, %{}))
      broadcast_status(state, :initializing, %{})
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_snapshot(state), state}
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    state = put_subscriber(state, subscriber)
    send_status(subscriber, state, state.status, state.runtime_metadata)
    {:reply, :ok, state}
  end

  def handle_call({:await_ready, _timeout}, _from, %{status: :ready} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:await_ready, timeout}, from, state) do
    waiter_id = make_ref()
    timer = Process.send_after(self(), {:ready_waiter_timeout, waiter_id}, timeout)
    waiter = %{from: from, timer: timer}
    {:noreply, put_in(state.ready_waiters[waiter_id], waiter)}
  end

  def handle_call({:start_thread, _params, _timeout}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :app_server_not_ready}, state}
  end

  def handle_call({:start_thread, params, timeout}, from, state) do
    case prepare_thread_params(params, state) do
      {:ok, params} ->
        params = Map.put_new(params, "cwd", state.cwd)
        {:noreply, send_request(state, "thread/start", params, :thread_start, from, timeout)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:resume_thread, _thread_id, _params, _timeout},
        _from,
        %{status: status} = state
      )
      when status != :ready do
    {:reply, {:error, :app_server_not_ready}, state}
  end

  def handle_call({:resume_thread, thread_id, params, timeout}, from, state) do
    case prepare_thread_params(params, state) do
      {:ok, params} ->
        params = Map.put(params, "threadId", thread_id)
        {:noreply, send_request(state, "thread/resume", params, :thread_resume, from, timeout)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:start_turn, _thread_id, _input, _params, _timeout},
        _from,
        %{
          status: status
        } = state
      )
      when status != :ready do
    {:reply, {:error, :app_server_not_ready}, state}
  end

  def handle_call({:start_turn, thread_id, input, params, timeout}, from, state) do
    params =
      params
      |> Map.put("threadId", thread_id)
      |> Map.put("input", input)

    {:noreply, send_request(state, "turn/start", params, :turn_start, from, timeout)}
  end

  def handle_call(
        {:reply_server_request, _request_id, _result},
        _from,
        %{status: status} = state
      )
      when status != :ready do
    {:reply, {:error, :app_server_not_ready}, state}
  end

  def handle_call({:reply_server_request, request_id, result}, _from, state) do
    case Port.command(state.port, JsonRpc.encode_result(request_id, result)) do
      true -> {:reply, :ok, state}
      false -> {:reply, {:error, :transport_failed}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    buffer = state.line_buffer <> chunk

    if byte_size(buffer) > @max_buffer_bytes do
      broadcast_protocol_error(state, :line_too_large)
      {:noreply, %{state | line_buffer: ""}}
    else
      {:noreply, %{state | line_buffer: buffer}}
    end
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.line_buffer <> chunk
    state = %{state | line_buffer: ""}

    case process_line(line, state) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:app_server_exited, status}
    state = fail_all_pending(state, reason)
    reply_ready_waiters(state.ready_waiters, {:error, reason})
    broadcast_status(state, :exited, %{exit_status: status})

    {:stop, reason, %{state | port: nil, status: :exited, pending: %{}, ready_waiters: %{}}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{kind: :initialize}, pending} ->
        reason = :initialize_timeout
        reply_ready_waiters(state.ready_waiters, {:error, reason})
        broadcast_status(state, :failed, %{reason: reason})

        {:stop, reason, %{state | status: :failed, pending: pending, ready_waiters: %{}}}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :request_timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:ready_waiter_timeout, waiter_id}, state) do
    case Map.pop(state.ready_waiters, waiter_id) do
      {nil, _waiters} ->
        {:noreply, state}

      {%{from: from}, waiters} ->
        GenServer.reply(from, {:error, :initialize_timeout})
        {:noreply, %{state | ready_waiters: waiters}}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        ^ref -> Map.delete(state.subscribers, pid)
        _other -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, %{port: port} = state) when is_port(port) do
    if state.status not in [:exited, :failed] do
      broadcast_status(state, :stopped, %{reason: inspect(reason)})
    end

    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp process_line("", state), do: {:ok, state}

  defp process_line(line, state) do
    case JsonRpc.decode(line) do
      {:ok, decoded} ->
        process_decoded(decoded, state)

      {:error, reason} ->
        broadcast_protocol_error(state, reason)
        {:ok, state}
    end
  end

  defp process_decoded({:response, id, result}, state) do
    complete_request(state, id, {:ok, result})
  end

  defp process_decoded({:error_response, id, error}, state) do
    complete_request(state, id, {:error, {:json_rpc, normalize_rpc_error(error)}})
  end

  defp process_decoded({:notification, _method, _params} = notification, state) do
    context = %{
      workspace_id: state.workspace_id,
      runtime_id: state.runtime_id,
      transport: :app_server,
      sequence: state.sequence + 1,
      occurred_at: DateTime.utc_now()
    }

    case Protocol.normalize(notification, context) do
      {:ok, event} ->
        broadcast_event(state, event)
        {:ok, %{state | sequence: event.sequence}}

      :ignore ->
        {:ok, state}

      {:error, reason} ->
        broadcast_protocol_error(state, reason)
        {:ok, state}
    end
  end

  defp process_decoded({:request, id, method, _params} = request, state) do
    case route_server_request(state.approval_broker, request) do
      {:ok, _approval} ->
        {:ok, state}

      {:error, :unsupported_server_request} ->
        error = JsonRpc.encode_error(id, -32_601, "Unsupported App Server request: #{method}")
        _ = Port.command(state.port, error)
        {:ok, state}

      {:error, reason} ->
        error = JsonRpc.encode_error(id, -32_602, "Invalid App Server request", inspect(reason))
        _ = Port.command(state.port, error)
        broadcast_protocol_error(state, {:invalid_server_request, method, reason})
        {:ok, state}
    end
  end

  defp complete_request(state, id, outcome) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        broadcast_protocol_error(state, :unknown_response_id)
        {:ok, state}

      {entry, pending} ->
        cancel_timer(entry.timer)
        state = %{state | pending: pending}
        complete_pending(entry, outcome, state)
    end
  end

  defp complete_pending(%{kind: :initialize}, {:ok, result}, state) do
    case Protocol.normalize_response(:initialize, result) do
      {:ok, metadata} ->
        _ = Port.command(state.port, JsonRpc.encode_notification("initialized"))
        reply_ready_waiters(state.ready_waiters, :ok)
        state = %{state | status: :ready, runtime_metadata: metadata, ready_waiters: %{}}
        broadcast_status(state, :ready, metadata)
        {:ok, state}

      {:error, reason} ->
        reply_ready_waiters(state.ready_waiters, {:error, reason})
        broadcast_status(state, :failed, %{reason: reason})

        {:stop, {:invalid_initialize_response, reason},
         %{state | status: :failed, ready_waiters: %{}}}
    end
  end

  defp complete_pending(%{kind: :initialize}, {:error, reason}, state) do
    reply_ready_waiters(state.ready_waiters, {:error, reason})
    broadcast_status(state, :failed, %{reason: reason})

    {:stop, {:initialize_failed, reason}, %{state | status: :failed, ready_waiters: %{}}}
  end

  defp complete_pending(%{kind: kind, from: from}, {:ok, result}, state) do
    reply =
      case Protocol.normalize_response(kind, result) do
        {:ok, normalized} -> {:ok, normalized}
        {:error, reason} -> {:error, {:invalid_response, reason}}
      end

    GenServer.reply(from, reply)
    {:ok, state}
  end

  defp complete_pending(%{from: from}, {:error, reason}, state) do
    GenServer.reply(from, {:error, reason})
    {:ok, state}
  end

  defp send_initialize(state, client_info) do
    client_info =
      %{
        "name" => "devide",
        "title" => "Casein",
        "version" => app_version()
      }
      |> Map.merge(string_key_map(client_info))

    send_request(
      state,
      "initialize",
      %{"clientInfo" => client_info},
      :initialize,
      nil,
      state.initialize_timeout
    )
  end

  defp send_request(state, method, params, kind, from, timeout) do
    id = state.request_id + 1
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)
    true = Port.command(state.port, JsonRpc.encode_request(id, method, params))
    entry = %{kind: kind, from: from, timer: timer}
    %{state | request_id: id, pending: Map.put(state.pending, id, entry)}
  end

  defp status_snapshot(state) do
    %{
      workspace_id: state.workspace_id,
      runtime_id: state.runtime_id,
      status: state.status,
      sequence: state.sequence,
      metadata: state.runtime_metadata,
      security: state.security
    }
  end

  defp put_subscriber(state, subscriber) do
    if Map.has_key?(state.subscribers, subscriber) do
      state
    else
      %{state | subscribers: Map.put(state.subscribers, subscriber, Process.monitor(subscriber))}
    end
  end

  defp broadcast_event(state, event) do
    event =
      case state.event_router do
        nil ->
          event

        router ->
          {:ok, routed_event} = EventRouter.publish(router, event)
          routed_event
      end

    Enum.each(Map.keys(state.subscribers), &send(&1, {:codex_event, event}))
  end

  defp broadcast_status(state, status, metadata) do
    if state.event_router do
      EventRouter.runtime_status(state.event_router, state.runtime_id, status, metadata)
    end

    Enum.each(
      Map.keys(state.subscribers),
      &send_status(&1, state, status, metadata)
    )
  end

  defp send_status(subscriber, state, status, metadata) do
    send(
      subscriber,
      {:codex_app_server_status, state.runtime_id, status,
       %{workspace_id: state.workspace_id, metadata: metadata}}
    )
  end

  defp broadcast_protocol_error(state, reason) do
    Enum.each(
      Map.keys(state.subscribers),
      &send(&1, {:codex_app_server_protocol_error, state.runtime_id, reason})
    )
  end

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, entry} ->
      cancel_timer(entry.timer)
      if entry.from, do: GenServer.reply(entry.from, {:error, reason})
    end)

    state
  end

  defp reply_ready_waiters(waiters, reply) do
    Enum.each(waiters, fn {_id, waiter} ->
      cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, reply)
    end)
  end

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: false

  defp normalize_rpc_error(error) do
    %{
      code: Map.get(error, "code"),
      message: Map.get(error, "message", "App Server request failed")
    }
  end

  defp normalize_input(input) when is_binary(input) and input != "" do
    {:ok, [%{"type" => "text", "text" => input}]}
  end

  defp normalize_input(input) when is_list(input) do
    if Enum.all?(input, &is_map/1), do: {:ok, input}, else: {:error, :invalid_turn_input}
  end

  defp normalize_input(_input), do: {:error, :invalid_turn_input}

  defp prepare_thread_params(params, state) do
    with {:ok, config} <- map_value(params, "config"),
         {:ok, shell_policy} <- map_value(config, "shell_environment_policy"),
         {:ok, set} <- map_value(shell_policy, "set"),
         {:ok, exclude} <- list_value(shell_policy, "exclude") do
      set = Map.drop(set, @sensitive_shell_env)
      exclude = Enum.uniq(exclude ++ @sensitive_shell_env)

      shell_policy =
        shell_policy
        |> Map.put("ignore_default_excludes", false)
        |> Map.put("exclude", exclude)
        |> Map.put("set", set)

      config = Map.put(config, "shell_environment_policy", shell_policy)

      {:ok,
       state.security
       |> Map.merge(params)
       |> Map.put("config", config)}
    end
  end

  defp map_value(map, key) do
    case Map.get(map, key, %{}) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {:invalid_thread_config, key}}
    end
  end

  defp list_value(map, key) do
    case Map.get(map, key, []) do
      value when is_list(value) ->
        if Enum.all?(value, &is_binary/1),
          do: {:ok, value},
          else: {:error, {:invalid_thread_config, key}}

      _other ->
        {:error, {:invalid_thread_config, key}}
    end
  end

  defp route_server_request(nil, _request), do: {:error, :unsupported_server_request}

  defp route_server_request(broker, request) do
    ApprovalBroker.request(broker, self(), request)
  catch
    :exit, reason -> {:error, {:approval_broker_unavailable, reason}}
  end

  defp security_defaults(opts) do
    case Keyword.get(opts, :workspace_mode, :manual) do
      :manual ->
        {:ok, %{"approvalPolicy" => "on-request", "sandbox" => "workspace-write"}}

      mode when mode in [:review, :agent_write_locked, :shared_stage_guarded] ->
        {:ok, %{"approvalPolicy" => "never", "sandbox" => "read-only"}}

      :unrestricted ->
        {:ok, %{"approvalPolicy" => "never", "sandbox" => "danger-full-access"}}

      mode ->
        {:error, {:invalid_workspace_mode, mode}}
    end
  end

  defp executable(opts) do
    case Keyword.get(opts, :executable) || System.find_executable("codex") do
      executable when is_binary(executable) and executable != "" -> {:ok, executable}
      _other -> {:error, :codex_app_server_unavailable}
    end
  end

  defp port_args(opts), do: Keyword.get(opts, :args, ["app-server", "--stdio"])

  defp valid_cwd(opts) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    if is_binary(cwd) and File.dir?(cwd), do: {:ok, cwd}, else: {:error, :invalid_cwd}
  end

  defp required_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_option, key}}
    end
  end

  defp open_port(executable, args, cwd, env) do
    options = [
      {:args, args},
      :binary,
      :exit_status,
      :hide,
      :use_stdio,
      {:line, @max_line_bytes},
      {:cd, cwd}
    ]

    options = if env == [], do: options, else: [{:env, env} | options]
    {:ok, Port.open({:spawn_executable, executable}, options)}
  rescue
    error -> {:error, {:port_open_failed, error}}
  end

  defp app_version do
    case Application.spec(:dev_ide, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end

  defp string_key_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
