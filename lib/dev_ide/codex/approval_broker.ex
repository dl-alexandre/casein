defmodule DevIDE.Codex.ApprovalBroker do
  @moduledoc """
  Single runtime-local authority for pending Codex approvals.

  Resolution is serialized through this process: it verifies the request is
  pending, replies through the owning App Server, records the terminal state,
  and emits a canonical event. This first slice retains records in memory; its
  API is shaped so durable storage can be added without changing callers.
  """

  use GenServer

  alias DevIDE.Codex.{AppServer, Approval, Event, EventRouter, Protocol}

  @type decision ::
          :accept
          | :accept_for_session
          | :decline
          | :cancel
          | {:accept_with_execpolicy_amendment, [String.t()]}
          | {:apply_network_policy_amendment, map()}
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

  @doc false
  @spec request(server(), GenServer.server(), DevIDE.Codex.JsonRpc.decoded()) ::
          {:ok, Approval.t()} | {:error, term()}
  def request(server, app_server, request) do
    GenServer.call(server, {:request, app_server, request})
  end

  @spec resolve(server(), String.t(), decision()) ::
          {:ok, Approval.t()} | {:error, term()}
  def resolve(server, approval_id, decision) when is_binary(approval_id) do
    GenServer.call(server, {:resolve, approval_id, decision})
  end

  @spec pending(server()) :: [Approval.t()]
  def pending(server), do: GenServer.call(server, :pending)

  @spec get(server(), String.t()) :: {:ok, Approval.t()} | {:error, :not_found}
  def get(server, approval_id), do: GenServer.call(server, {:get, approval_id})

  @impl true
  def init(opts) do
    {:ok,
     %{
       workspace_id: Keyword.fetch!(opts, :workspace_id),
       runtime_id: Keyword.fetch!(opts, :runtime_id),
       event_router: Keyword.fetch!(opts, :event_router),
       pending: %{},
       resolved: %{},
       request_index: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:request, app_server, request}, _from, state) do
    context = %{
      workspace_id: state.workspace_id,
      runtime_id: state.runtime_id,
      transport: :app_server,
      sequence: 1,
      occurred_at: DateTime.utc_now()
    }

    with {:ok, approval} <- normalize_request(request, context),
         :ok <- ensure_new_request(state, app_server, approval.request_id),
         {:ok, _event} <- EventRouter.publish(state.event_router, requested_event(approval)) do
      state = put_pending(state, app_server, approval)
      {:reply, {:ok, approval}, state}
    else
      :unsupported -> {:reply, {:error, :unsupported_server_request}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve, approval_id, decision}, _from, state) do
    case Map.fetch(state.pending, approval_id) do
      :error ->
        reason =
          if Map.has_key?(state.resolved, approval_id), do: :already_resolved, else: :not_found

        {:reply, {:error, reason}, state}

      {:ok, entry} ->
        resolve_pending(entry, decision, state)
    end
  end

  def handle_call(:pending, _from, state) do
    approvals =
      state.pending
      |> Map.values()
      |> Enum.map(& &1.approval)
      |> Enum.sort_by(&DateTime.to_unix(&1.requested_at, :microsecond))

    {:reply, approvals, state}
  end

  def handle_call({:get, approval_id}, _from, state) do
    approval =
      case Map.get(state.pending, approval_id) do
        nil -> Map.get(state.resolved, approval_id)
        entry -> entry.approval
      end

    if approval,
      do: {:reply, {:ok, approval}, state},
      else: {:reply, {:error, :not_found}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, app_server, reason}, state) do
    case Map.get(state.monitors, app_server) do
      %{ref: ^ref, approval_ids: approval_ids} ->
        state =
          Enum.reduce(approval_ids, state, fn approval_id, acc ->
            fail_transport(acc, approval_id, reason)
          end)

        {:noreply, %{state | monitors: Map.delete(state.monitors, app_server)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp normalize_request(request, context) do
    Protocol.normalize_server_request(request, context)
  end

  defp ensure_new_request(state, app_server, request_id) do
    if Map.has_key?(state.request_index, {app_server, request_id}),
      do: {:error, :duplicate_server_request},
      else: :ok
  end

  defp put_pending(state, app_server, approval) do
    entry = %{approval: approval, app_server: app_server}
    pending = Map.put(state.pending, approval.id, entry)
    request_index = Map.put(state.request_index, {app_server, approval.request_id}, approval.id)

    monitors =
      case Map.fetch(state.monitors, app_server) do
        :error ->
          Map.put(state.monitors, app_server, %{
            ref: Process.monitor(app_server),
            approval_ids: MapSet.new([approval.id])
          })

        {:ok, monitor} ->
          Map.put(state.monitors, app_server, %{
            monitor
            | approval_ids: MapSet.put(monitor.approval_ids, approval.id)
          })
      end

    %{state | pending: pending, request_index: request_index, monitors: monitors}
  end

  defp resolve_pending(entry, decision, state) do
    with {:ok, response, status, resolution} <- approval_response(entry.approval, decision),
         :ok <- safe_transport_reply(entry, response) do
      approval = resolve_approval(entry.approval, status, resolution)
      {:ok, _event} = EventRouter.publish(state.event_router, resolved_event(approval))
      state = move_to_resolved(state, entry, approval)
      {:reply, {:ok, approval}, state}
    else
      {:error, :transport_failed = reason} ->
        approval = resolve_approval(entry.approval, :transport_failed, reason)
        {:ok, _event} = EventRouter.publish(state.event_router, resolved_event(approval))
        state = move_to_resolved(state, entry, approval)
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp safe_transport_reply(entry, response) do
    case AppServer.reply_server_request(entry.app_server, entry.approval.request_id, response) do
      :ok -> :ok
      {:error, _reason} -> {:error, :transport_failed}
    end
  catch
    :exit, _reason -> {:error, :transport_failed}
  end

  defp approval_response(%Approval{kind: kind}, decision)
       when kind in [:command_execution, :file_change] do
    case decision do
      :accept -> {:ok, %{"decision" => "accept"}, :granted, :accept}
      :accept_for_session -> {:ok, %{"decision" => "acceptForSession"}, :granted, decision}
      :decline -> {:ok, %{"decision" => "decline"}, :denied, decision}
      :cancel -> {:ok, %{"decision" => "cancel"}, :cancelled, decision}
      custom -> custom_command_response(kind, custom)
    end
  end

  defp approval_response(%Approval{kind: :permissions, payload: payload}, decision) do
    requested = Map.get(payload, :permissions, %{})

    case decision do
      :accept ->
        {:ok, %{"permissions" => requested, "scope" => "turn"}, :granted, decision}

      :accept_for_session ->
        {:ok, %{"permissions" => requested, "scope" => "session"}, :granted, decision}

      :decline ->
        {:ok, %{"permissions" => %{}, "scope" => "turn"}, :denied, decision}

      :cancel ->
        {:ok, %{"permissions" => %{}, "scope" => "turn"}, :cancelled, decision}

      _other ->
        {:error, :invalid_decision}
    end
  end

  defp custom_command_response(
         :command_execution,
         {:accept_with_execpolicy_amendment, amendment}
       )
       when is_list(amendment) do
    decision = %{
      "acceptWithExecpolicyAmendment" => %{"execpolicy_amendment" => amendment}
    }

    {:ok, %{"decision" => decision}, :granted, :accept_with_execpolicy_amendment}
  end

  defp custom_command_response(
         :command_execution,
         {:apply_network_policy_amendment, amendment}
       )
       when is_map(amendment) do
    decision = %{
      "applyNetworkPolicyAmendment" => %{"network_policy_amendment" => amendment}
    }

    {:ok, %{"decision" => decision}, :granted, :apply_network_policy_amendment}
  end

  defp custom_command_response(_kind, _decision), do: {:error, :invalid_decision}

  defp resolve_approval(approval, status, resolution) do
    %{
      approval
      | status: status,
        resolved_at: DateTime.utc_now(),
        resolution: resolution
    }
  end

  defp move_to_resolved(state, entry, approval) do
    state
    |> remove_pending(entry.approval.id, entry)
    |> Map.update!(:resolved, &Map.put(&1, approval.id, approval))
  end

  defp remove_pending(state, approval_id, entry) do
    pending = Map.delete(state.pending, approval_id)
    request_index = Map.delete(state.request_index, {entry.app_server, entry.approval.request_id})

    monitors =
      case Map.get(state.monitors, entry.app_server) do
        nil ->
          state.monitors

        monitor ->
          approval_ids = MapSet.delete(monitor.approval_ids, approval_id)

          if MapSet.size(approval_ids) == 0 do
            Process.demonitor(monitor.ref, [:flush])
            Map.delete(state.monitors, entry.app_server)
          else
            Map.put(state.monitors, entry.app_server, %{monitor | approval_ids: approval_ids})
          end
      end

    %{state | pending: pending, request_index: request_index, monitors: monitors}
  end

  defp fail_transport(state, approval_id, reason) do
    case Map.get(state.pending, approval_id) do
      nil ->
        state

      entry ->
        approval = resolve_approval(entry.approval, :transport_failed, reason)
        {:ok, _event} = EventRouter.publish(state.event_router, resolved_event(approval))

        state
        |> remove_pending(approval_id, entry)
        |> Map.update!(:resolved, &Map.put(&1, approval.id, approval))
    end
  end

  defp requested_event(approval) do
    Event.new!(
      :approval_requested,
      event_context(approval, approval.requested_at),
      thread_id: approval.thread_id,
      turn_id: approval.turn_id,
      item_id: approval.item_id,
      request_id: approval.request_id,
      payload:
        Map.merge(approval.payload, %{
          approval_id: approval.id,
          approval_kind: approval.kind,
          status: approval.status
        }),
      metadata: approval.metadata
    )
  end

  defp resolved_event(approval) do
    Event.new!(
      :approval_resolved,
      event_context(approval, approval.resolved_at),
      thread_id: approval.thread_id,
      turn_id: approval.turn_id,
      item_id: approval.item_id,
      request_id: approval.request_id,
      payload: %{
        approval_id: approval.id,
        approval_kind: approval.kind,
        status: approval.status,
        resolution: approval.resolution
      },
      metadata: approval.metadata
    )
  end

  defp event_context(approval, occurred_at) do
    %{
      workspace_id: approval.workspace_id,
      runtime_id: approval.runtime_id,
      transport: :app_server,
      sequence: 1,
      occurred_at: occurred_at
    }
  end
end
