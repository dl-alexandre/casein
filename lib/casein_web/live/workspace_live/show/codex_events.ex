defmodule CaseinWeb.WorkspaceLive.Show.CodexEvents do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import CaseinWeb.WorkspaceLive.Show.Context

  alias Casein.AgentSessions.Provider.PendingRequest
  alias Casein.Codex.{Event, EventSink, ExecRun, Store}
  alias CaseinWeb.WorkspaceLive.Show.AgentApprovalState

  @delta_flush_ms 150
  @max_live_delta_bytes 32_000

  @doc "Seed Codex state shared by Notifications, History, and Run without domain reads."
  def assign_defaults(socket) do
    socket
    |> assign(:codex_loaded?, false)
    |> assign(:codex_subscribed?, false)
    |> assign(:codex_threads, [])
    |> assign(:codex_approvals, [])
    |> assign(:codex_pending_requests, [])
    |> assign(:codex_pending_approval_count, 0)
    |> AgentApprovalState.assign_pending_count()
    |> assign(:codex_selected_thread_id, nil)
    |> assign(:codex_timeline, [])
    |> assign(:codex_live_delta, "")
    |> assign(:codex_delta_buffer, [])
    |> assign(:codex_delta_timer, nil)
    |> assign(:codex_exec_form, to_form(%{"prompt" => ""}, as: :codex_exec))
    |> assign(:codex_exec_run, nil)
    |> assign(:codex_error, nil)
  end

  @doc "Subscribe once to canonical Codex events for the mounted workspace."
  def subscribe_once(socket) do
    if connected?(socket) and not socket.assigns.codex_subscribed? do
      :ok = EventSink.subscribe(socket.assigns.workspace.id)
      assign(socket, :codex_subscribed?, true)
    else
      socket
    end
  end

  @doc "Load compact thread/approval projections and the selected timeline."
  def open(socket) do
    if connected?(socket) do
      socket
      |> subscribe_once()
      |> refresh()
      |> assign(:codex_loaded?, true)
    else
      socket
    end
  end

  @doc "Refresh the workspace projection without replaying the event ledger."
  def refresh(socket) do
    snapshot = Store.workspace_snapshot(socket.assigns.workspace.id, limit: 200)
    threads = snapshot.threads
    approvals = snapshot.approvals

    selected_thread_id =
      selected_thread_id(socket.assigns.codex_selected_thread_id, threads)

    socket
    |> assign(:codex_threads, threads)
    |> assign(:codex_approvals, approvals)
    |> assign(:codex_pending_requests, pending_requests(approvals))
    |> assign(:codex_pending_approval_count, pending_count(approvals))
    |> AgentApprovalState.assign_pending_count()
    |> assign(:codex_selected_thread_id, selected_thread_id)
    |> assign_timeline(selected_thread_id)
    |> assign(:codex_error, nil)
  rescue
    error -> assign(socket, :codex_error, Exception.message(error))
  end

  def handle_event("codex:refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("codex:select_thread", %{"thread-id" => thread_id}, socket)
      when is_binary(thread_id) and thread_id != "" do
    if Enum.any?(socket.assigns.codex_threads, &(&1.thread_id == thread_id)) do
      {:noreply,
       socket
       |> assign(:codex_selected_thread_id, thread_id)
       |> assign(:codex_live_delta, "")
       |> assign_timeline(thread_id)}
    else
      {:noreply, put_flash(socket, :error, "That Codex thread is no longer available.")}
    end
  end

  def handle_event("codex:start_exec", %{"codex_exec" => %{"prompt" => prompt}}, socket) do
    prompt = String.trim(prompt)

    with true <- prompt != "",
         {:ok, root} <- home_host_path(socket),
         {:ok, pid, run_id} <-
           ExecRun.start(socket.assigns.workspace.id, root, prompt,
             actor_id: current_actor_id(socket),
             sandbox: :read_only
           ),
         {:ok, snapshot} <- ExecRun.subscribe(pid) do
      {:noreply,
       socket
       |> assign(:codex_exec_run, Map.put(snapshot, :run_id, run_id))
       |> assign(:codex_exec_form, to_form(%{"prompt" => ""}, as: :codex_exec))
       |> put_flash(:info, "Read-only Codex job started.")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Enter a task for Codex.")}

      :error ->
        {:noreply, put_flash(socket, :error, "Workspace path is unavailable.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Codex job failed: #{inspect(reason)}")}
    end
  end

  def handle_event("codex:cancel_exec", _params, socket) do
    case socket.assigns.codex_exec_run do
      %{run_id: run_id, status: :running} ->
        ExecRun.cancel(run_id)
        {:noreply, put_flash(socket, :info, "Cancelling Codex job…")}

      _other ->
        {:noreply, socket}
    end
  end

  @doc "Apply a canonical PubSub event, batching only high-frequency message deltas."
  def handle_info(%Event{type: :agent_message_delta} = event, socket) do
    if history_active?(socket) and event.thread_id == socket.assigns.codex_selected_thread_id do
      delta = payload_value(event.payload, :delta)
      buffer = if is_binary(delta), do: [delta | socket.assigns.codex_delta_buffer], else: []

      socket = assign(socket, :codex_delta_buffer, buffer)

      if socket.assigns.codex_delta_timer do
        {:noreply, socket}
      else
        timer = Process.send_after(self(), :flush_codex_deltas, @delta_flush_ms)
        {:noreply, assign(socket, :codex_delta_timer, timer)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Event{} = event, socket) do
    socket =
      if event.workspace_id == socket.assigns.workspace.id and
           (history_active?(socket) or approval_event?(event)) do
        socket
        |> maybe_clear_completed_delta(event)
        |> refresh()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(:flush_codex_deltas, socket) do
    delta = socket.assigns.codex_delta_buffer |> Enum.reverse() |> IO.iodata_to_binary()

    live_delta =
      (socket.assigns.codex_live_delta <> delta)
      |> retain_tail(@max_live_delta_bytes)

    {:noreply,
     assign(socket,
       codex_live_delta: live_delta,
       codex_delta_buffer: [],
       codex_delta_timer: nil
     )}
  end

  def handle_info({:codex_exec_event, _run_id, _event}, socket), do: {:noreply, socket}

  def handle_info({:codex_exec_data, run_id, :stderr, data}, socket) do
    {:noreply,
     update_exec(socket, run_id, fn run -> Map.put(run, :stderr, retain_tail(data, 8_000)) end)}
  end

  def handle_info({:codex_exec_exit, run_id, exit_code, status}, socket) do
    socket =
      socket
      |> update_exec(run_id, &Map.merge(&1, %{exit_code: exit_code, status: status}))
      |> refresh()

    {:noreply, socket}
  end

  defp assign_timeline(socket, nil), do: assign(socket, :codex_timeline, [])

  defp assign_timeline(socket, thread_id) do
    timeline = Store.timeline(socket.assigns.workspace.id, thread_id, limit: 300)
    assign(socket, :codex_timeline, timeline)
  end

  defp selected_thread_id(current, threads) do
    cond do
      is_binary(current) and Enum.any?(threads, &(&1.thread_id == current)) -> current
      threads != [] -> hd(threads).thread_id
      true -> nil
    end
  end

  defp pending_count(approvals), do: Enum.count(approvals, &(&1.status == "pending"))

  defp pending_requests(approvals) do
    approvals
    |> Enum.filter(&(&1.status == "pending"))
    |> Enum.map(fn approval ->
      PendingRequest.new(%{
        provider_id: :codex,
        session_ref: %{
          provider_id: :codex,
          runtime_id: approval.runtime_id,
          thread_id: approval.thread_id
        },
        request_id: approval.id,
        title: approval_title(approval.kind),
        detail: approval_detail(approval.payload),
        options: nil,
        requested_at: approval.requested_at,
        metadata: approval.metadata
      })
    end)
  end

  defp history_active?(socket), do: socket.assigns[:tab] == "history"

  defp approval_event?(%Event{type: type}),
    do: type in [:approval_requested, :approval_resolved]

  defp approval_title(:command_execution), do: "Command execution"
  defp approval_title(:file_change), do: "File changes"
  defp approval_title(:permissions), do: "Additional permissions"

  defp approval_title(kind),
    do: kind |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp approval_detail(payload) do
    payload_value(payload, :command) || payload_value(payload, :grant_root) ||
      payload_value(payload, :reason)
  end

  defp payload_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp retain_tail(value, bytes) when is_binary(value) and byte_size(value) > bytes,
    do: binary_part(value, byte_size(value) - bytes, bytes)

  defp retain_tail(value, _bytes) when is_binary(value), do: value
  defp retain_tail(_value, _bytes), do: ""

  defp update_exec(socket, run_id, fun) do
    case socket.assigns.codex_exec_run do
      %{run_id: ^run_id} = run -> assign(socket, :codex_exec_run, fun.(run))
      _other -> socket
    end
  end

  defp maybe_clear_completed_delta(socket, %Event{type: type, thread_id: thread_id})
       when type in [:turn_completed, :turn_failed] do
    if thread_id == socket.assigns.codex_selected_thread_id,
      do: assign(socket, :codex_live_delta, ""),
      else: socket
  end

  defp maybe_clear_completed_delta(socket, _event), do: socket
end
