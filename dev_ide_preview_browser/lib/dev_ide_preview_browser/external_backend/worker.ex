defmodule DevIDEPreviewBrowser.ExternalBackend.Worker do
  @moduledoc false

  use GenServer

  alias DevIDEPreviewBrowser.ExternalBackend.Protocol

  defstruct [
    :port,
    :event_owner,
    next_id: 1,
    pending: %{},
    browsers: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def request(worker, command, payload, timeout) do
    call_timeout = call_timeout(timeout)
    GenServer.call(worker, {:request, command, payload, timeout}, call_timeout)
  catch
    :exit, reason -> {:error, {:worker_exit, reason}}
  end

  @impl true
  def init(opts) do
    with {:ok, executable} <- fetch_executable(opts),
         {:ok, port} <- open_port(executable, opts) do
      {:ok, %__MODULE__{port: port, event_owner: Keyword.get(opts, :event_owner)}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, command, payload, timeout}, from, %__MODULE__{} = state) do
    id = Integer.to_string(state.next_id)

    case Protocol.encode_request(id, command, payload) do
      {:ok, encoded} ->
        if Port.command(state.port, encoded <> "\n") do
          timer_ref = maybe_start_timer(id, timeout)

          pending =
            Map.put(state.pending, id, %{
              from: from,
              command: command,
              payload: payload,
              timer_ref: timer_ref
            })

          {:noreply, %{state | next_id: state.next_id + 1, pending: pending}}
        else
          {:reply, {:error, :port_closed}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:encode_failed, reason}}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {_line_state, line}}}, %__MODULE__{port: port} = state) do
    handle_line(line, state)
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    emit_crash_events(state, {:port_exit, status})

    Enum.each(state.pending, fn {_id, pending} ->
      cancel_timer(pending.timer_ref)
      GenServer.reply(pending.from, {:error, {:port_exit, status}})
    end)

    {:stop, {:shutdown, {:port_exit, status}}, %{state | pending: %{}}}
  end

  def handle_info({:request_timeout, id}, %__MODULE__{} = state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {pending, pending_requests} ->
        GenServer.reply(pending.from, {:error, :request_timeout})
        {:noreply, %{state | pending: pending_requests}}
    end
  end

  @impl true
  def terminate(_reason, %__MODULE__{port: port}) do
    if port_open?(port), do: Port.close(port)
    :ok
  catch
    :error, _reason -> :ok
  end

  defp handle_line(line, %__MODULE__{} = state) when is_binary(line) do
    case Protocol.decode_line(line) do
      {:ok, {:event, browser_id, event}} ->
        deliver_event(browser_id, event, state)
        {:noreply, state}

      {:ok, {:response, id, reply}} ->
        reply_to_pending(id, reply, state)

      {:ok, :ignore} ->
        {:noreply, state}

      {:error, error} ->
        reply_all({:error, error}, state)
    end
  end

  defp reply_to_pending(id, reply, %__MODULE__{} = state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {request, pending} ->
        cancel_timer(request.timer_ref)
        GenServer.reply(request.from, reply)
        {:noreply, %{state | pending: pending, browsers: track_browser(state, request, reply)}}
    end
  end

  defp reply_all(reply, %__MODULE__{} = state) do
    Enum.each(state.pending, fn {_id, pending} ->
      cancel_timer(pending.timer_ref)
      GenServer.reply(pending.from, reply)
    end)

    {:noreply, %{state | pending: %{}}}
  end

  defp deliver_event(browser_id, event, %__MODULE__{event_owner: owner})
       when is_pid(owner) do
    send(owner, {:preview_browser, browser_id, event})
    :ok
  end

  defp deliver_event(_browser_id, _event, _state), do: :ok

  defp emit_crash_events(%__MODULE__{event_owner: owner, browsers: browsers}, reason)
       when is_pid(owner) do
    browsers
    |> Map.values()
    |> Enum.uniq()
    |> Enum.each(fn browser_id ->
      send(owner, {:preview_browser, browser_id, {:crashed, reason}})
    end)
  end

  defp emit_crash_events(_state, _reason), do: :ok

  defp track_browser(
         %__MODULE__{} = state,
         %{command: "open_browser", payload: payload},
         {:ok, result}
       ) do
    browser_id = Map.get(payload, "browser_id")
    browser_ref = Map.get(result, "browser_ref", browser_id)

    if is_binary(browser_id) and is_binary(browser_ref) do
      Map.put(state.browsers, browser_ref, browser_id)
    else
      state.browsers
    end
  end

  defp track_browser(
         %__MODULE__{} = state,
         %{command: "close_browser", payload: payload},
         {:ok, _result}
       ) do
    browser_ref = Map.get(payload, "browser_ref")

    if is_binary(browser_ref) do
      Map.delete(state.browsers, browser_ref)
    else
      state.browsers
    end
  end

  defp track_browser(%__MODULE__{} = state, _request, _reply), do: state.browsers

  defp fetch_executable(opts) do
    case Keyword.fetch(opts, :executable) do
      {:ok, executable} when is_binary(executable) and executable != "" -> {:ok, executable}
      {:ok, _executable} -> {:error, :invalid_executable}
      :error -> {:error, :missing_executable}
    end
  end

  defp open_port(executable, opts) do
    port_opts =
      [
        :binary,
        :exit_status,
        {:line, Keyword.get(opts, :line_length, 65_536)},
        {:args, Keyword.get(opts, :args, [])}
      ]
      |> maybe_put_port_opt(:cd, Keyword.get(opts, :cd))
      |> maybe_put_port_opt(:env, Keyword.get(opts, :env))

    {:ok, Port.open({:spawn_executable, executable}, port_opts)}
  rescue
    error -> {:error, {:port_open_failed, error}}
  end

  defp maybe_put_port_opt(opts, _key, nil), do: opts
  defp maybe_put_port_opt(opts, key, value), do: [{key, value} | opts]

  defp port_open?(port), do: is_port(port) and not is_nil(Port.info(port))

  defp maybe_start_timer(_id, :infinity), do: nil

  defp maybe_start_timer(id, timeout) when is_integer(timeout) and timeout >= 0 do
    Process.send_after(self(), {:request_timeout, id}, timeout)
  end

  defp maybe_start_timer(_id, _timeout), do: nil

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout), do: timeout + 1_000
  defp call_timeout(timeout), do: timeout
end
