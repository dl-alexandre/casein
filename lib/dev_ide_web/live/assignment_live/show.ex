defmodule DevIdeWeb.AssignmentLive.Show do
  @moduledoc """
  Timeline, inspection, execution output, and recovery-action view
  for a single assignment.

  Shows:
    * Assignment projection summary
    * Event stream with sequence numbers
    * Reducer trace (state transition per event)
    * Execution timeline from protocol events
    * Live output stream (stdout/stderr)
    * Recovery proposals (read-first, operator-initiated)

  Subscribes to both assignment projections and fleet execution
  events for real-time updates.
  """

  use DevIdeWeb, :live_view

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Event, as: AssignmentEvent
  alias DevIDE.Assignments.Notification, as: AssignmentNotification
  alias DevIDE.Assignments.Recovery
  alias DevIDE.Assignments.Reducer
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.Approvals
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.Notification
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Fleet.RecoveryAuth
  alias DevIDE.Runs.Status
  alias DevIdeWeb.Plugs.AssignCurrentUser

  @max_execution_timeline_events 100
  @max_output_chunks 500

  @recovery_proposal_event_types [
    :claimed,
    :started,
    :completed,
    :failed,
    :abandoned,
    :expired
  ]

  @impl true
  def mount(%{"id" => id}, session, socket) do
    if connected?(socket) do
      DevIDE.Assignments.subscribe(id)
      Phoenix.PubSub.subscribe(DevIde.PubSub, "fleet:assignments:#{id}")
    end

    socket =
      socket
      |> assign_new(:current_scope, fn -> nil end)
      |> assign(:current_user, AssignCurrentUser.from_session(session))

    {:ok, refresh(socket, id)}
  end

  @impl true
  def handle_info({DevIDE.Assignments, %AssignmentNotification{} = n}, socket) do
    if n.assignment_id == socket.assigns.assignment_id do
      {:noreply, apply_assignment_notification(socket, n)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({DevIDE.Fleet.Registry, %Notification{} = n}, socket) do
    if n.assignment_id == socket.assigns.assignment_id do
      socket =
        socket
        |> update_lease_topology(n)
        |> update_execution_timeline(n)
        |> maybe_append_output(n)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({DevIDE.Fleet.LocalRunnerAdapter, %Notification{} = n}, socket) do
    if n.assignment_id == socket.assigns.assignment_id do
      socket =
        socket
        |> update_execution_timeline(n)
        |> maybe_append_output(n)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, refresh(socket, socket.assigns.assignment_id)}
  end

  @impl true
  def handle_event("dry_run", %{"action_id" => action_id}, socket) do
    action = Enum.find(socket.assigns.proposals, &(&1.id == action_id))

    if action do
      case Recovery.dry_run(action) do
        {:ok, result} ->
          updated =
            Enum.map(socket.assigns.proposals, fn p ->
              if p.id == action_id, do: result, else: p
            end)

          {:noreply, assign(socket, :proposals, updated)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Dry-run failed: #{reason}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("request_recovery_approval", %{"action_id" => action_id}, socket) do
    action = Enum.find(socket.assigns.proposals, &(&1.id == action_id))

    if action && socket.assigns.projection &&
         RecoveryAuth.can_request_recovery?(recovery_actor(socket), socket.assigns.projection) do
      operator_id = operator_id(socket)

      case Fleet.request_approval(
             action.kind,
             %{
               type: "assignment",
               ref: action.assignment_id,
               workspace_id: socket.assigns.projection.workspace_id
             },
             actor_id: operator_id,
             reason: "operator requested recovery approval"
           ) do
        {:ok, _approval} ->
          {:noreply,
           socket
           |> put_flash(:info, "Recovery approval requested.")
           |> refresh(socket.assigns.assignment_id)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Approval request failed: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, recovery_denied_message())}
    end
  end

  @impl true
  def handle_event("grant_recovery_approval", %{"approval_id" => approval_id}, socket) do
    if RecoveryAuth.can_grant_recovery?(recovery_actor(socket)) do
      do_grant_recovery_approval(socket, approval_id)
    else
      {:noreply, put_flash(socket, :error, recovery_denied_message())}
    end
  end

  @impl true
  def handle_event("apply_recovery", %{"action_id" => action_id}, socket) do
    action = Enum.find(socket.assigns.proposals, &(&1.id == action_id))

    if action &&
         RecoveryAuth.can_apply_recovery?(recovery_actor(socket), socket.assigns.projection) do
      approval = granted_approval(socket.assigns.approval_decisions, action)

      case Fleet.apply_approved_recovery(action, approval && approval.id, operator_id(socket)) do
        {:ok, _applied} ->
          socket =
            socket
            |> put_flash(:info, "Recovery action applied successfully.")
            |> refresh(socket.assigns.assignment_id)

          {:noreply, socket}

        {:error, :stale} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Proposal is stale — assignment state has changed. Refresh to see current proposals."
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Apply failed: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, recovery_denied_message())}
    end
  end

  @impl true
  def handle_event("dismiss_recovery", %{"action_id" => action_id}, socket) do
    if RecoveryAuth.can_dismiss_recovery?(recovery_actor(socket), socket.assigns.projection) do
      remaining = Enum.reject(socket.assigns.proposals, &(&1.id == action_id))
      {:noreply, assign(socket, :proposals, remaining)}
    else
      {:noreply, put_flash(socket, :error, recovery_denied_message())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl p-6 space-y-6">
        <header class="flex items-center justify-between">
          <div>
            <.link navigate={~p"/assignments"} class="text-sm text-blue-700 hover:underline">
              ← Assignments
            </.link>
            <h1 class="text-2xl font-semibold">Assignment {@assignment_id}</h1>
            <p class="text-xs text-zinc-500 font-mono">
              {portfolio_summary(@portfolio)}
            </p>
          </div>
          <button
            phx-click="refresh"
            class="text-xs rounded border px-2 py-1 hover:bg-zinc-50"
          >
            Refresh
          </button>
        </header>

        <%= if @projection do %>
          <section class="rounded border p-4 space-y-2">
            <h2 class="text-sm font-medium text-zinc-700">Projection</h2>
            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
              <dt class="text-zinc-500">state</dt>
              <dd class={state_badge_class(@projection.state)}>{@projection.state}</dd>
              <dt class="text-zinc-500">workspace</dt>
              <dd class="font-mono">{@projection.workspace_id}</dd>
              <dt class="text-zinc-500">run</dt>
              <dd class="font-mono">{@projection.run_id || "—"}</dd>
              <dt class="text-zinc-500">lease owner</dt>
              <dd class="font-mono">{@projection.lease_owner || "—"}</dd>
              <dt class="text-zinc-500">expires</dt>
              <dd class="font-mono">
                <%= if @projection.lease_expires_at do %>
                  {format_dt(@projection.lease_expires_at)}
                <% else %>
                  —
                <% end %>
              </dd>
              <dt class="text-zinc-500">failure</dt>
              <dd class="font-mono">{@projection.failure_reason || "—"}</dd>
            </dl>
          </section>
        <% end %>

        <%= if @execution_timeline_count > 0 do %>
          <section class="space-y-2">
            <h2 class="text-sm font-medium text-zinc-700">
              Execution Timeline ({@execution_timeline_count} events)
            </h2>
            <ol id="assignment-execution-timeline" phx-update="stream" class="space-y-1">
              <%= for {dom_id, entry} <- @streams.execution_timeline do %>
                <li
                  id={dom_id}
                  class="rounded border px-3 py-1.5 text-xs flex items-center gap-2"
                >
                  <span class={execution_kind_class(entry.kind)}>
                    {entry.kind}
                  </span>
                  <%= if entry.runner_id do %>
                    <span class="font-mono text-zinc-500">
                      runner {String.slice(entry.runner_id, 0, 8)}…
                    </span>
                  <% end %>
                  <span class="text-zinc-400 ml-auto">
                    {format_dt(entry.occurred_at)}
                  </span>
                </li>
              <% end %>
            </ol>
          </section>
        <% end %>

        <%= if @output_chunks_count > 0 do %>
          <section class="space-y-2">
            <h2 class="text-sm font-medium text-zinc-700">
              Live Output ({@output_chunks_count} retained chunks)
            </h2>
            <div
              id="assignment-output-chunks"
              phx-update="stream"
              class="rounded border bg-zinc-900 p-3 font-mono text-xs text-zinc-300 overflow-auto max-h-96"
            >
              <%= for {dom_id, chunk} <- @streams.output_chunks do %>
                <div id={dom_id} class={output_stream_class(chunk.stream)}>
                  {chunk.chunk}
                </div>
              <% end %>
            </div>
          </section>
        <% end %>

        <%= if @proposals != [] do %>
          <section class="space-y-2">
            <h2 class="text-sm font-medium text-zinc-700">
              Recovery Proposals ({length(@proposals)})
            </h2>
            <div class="space-y-2">
              <%= for proposal <- @proposals do %>
                <div
                  id={"recovery-proposal-#{proposal.id}"}
                  class={[
                    "rounded border px-3 py-2 text-xs",
                    risk_level_border(proposal.risk_level)
                  ]}
                >
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span class={risk_level_badge(proposal.risk_level)}>
                        {proposal.risk_level}
                      </span>
                      <span class="font-mono font-medium">{proposal.kind}</span>
                    </div>
                    <div class="flex items-center gap-1">
                      <%= if proposal.dry_run_result do %>
                        <span class="text-green-600">dry-run ready</span>
                      <% end %>
                      <button
                        phx-click="dismiss_recovery"
                        phx-value-action_id={proposal.id}
                        class="text-zinc-400 hover:text-zinc-600"
                      >
                        <.icon name="hero-x-mark" class="w-3 h-3" />
                      </button>
                    </div>
                  </div>
                  <p class="mt-1 text-zinc-600">{proposal.reason}</p>

                  <%= if proposal.dry_run_result do %>
                    <details class="mt-2">
                      <summary class="cursor-pointer text-[10px] text-zinc-400">
                        dry-run result
                      </summary>
                      <pre class="mt-1 text-[10px] font-mono bg-zinc-50 p-1 rounded overflow-auto">
                        {inspect(proposal.dry_run_result, pretty: true)}
                      </pre>
                    </details>
                  <% end %>

                  <div class="mt-2 flex items-center gap-2">
                    <%= if not proposal.dry_run_result do %>
                      <button
                        id={"dry-run-recovery-#{proposal.id}"}
                        phx-click="dry_run"
                        phx-value-action_id={proposal.id}
                        class="text-[10px] rounded border px-2 py-0.5 hover:bg-zinc-50"
                      >
                        Dry-run
                      </button>
                    <% else %>
                      <%= if granted_approval(@approval_decisions, proposal) do %>
                        <button
                          id={"apply-recovery-#{proposal.id}"}
                          phx-click="apply_recovery"
                          phx-value-action_id={proposal.id}
                          class={[
                            "text-[10px] rounded border px-2 py-0.5",
                            if(proposal.risk_level == :safe,
                              do: "hover:bg-green-50 text-green-700",
                              else: "hover:bg-amber-50 text-amber-700"
                            )
                          ]}
                        >
                          Apply
                        </button>
                      <% else %>
                        <%= if requested_approval(@approval_decisions, proposal) do %>
                          <button
                            id={"grant-recovery-approval-#{proposal.id}"}
                            phx-click="grant_recovery_approval"
                            phx-value-approval_id={
                              requested_approval(@approval_decisions, proposal).id
                            }
                            class="text-[10px] rounded border px-2 py-0.5 hover:bg-blue-50 text-blue-700"
                          >
                            Approve
                          </button>
                        <% else %>
                          <button
                            id={"request-recovery-approval-#{proposal.id}"}
                            phx-click="request_recovery_approval"
                            phx-value-action_id={proposal.id}
                            class="text-[10px] rounded border px-2 py-0.5 hover:bg-amber-50 text-amber-700"
                          >
                            Request approval
                          </button>
                        <% end %>
                      <% end %>
                    <% end %>
                    <%= if proposal.dry_run_result && latest_approval(@approval_decisions, proposal) do %>
                      <span class="text-[10px] text-zinc-500">
                        approval {latest_approval(@approval_decisions, proposal).status}
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </section>
        <% end %>

        <section class="space-y-2">
          <h2 class="text-sm font-medium text-zinc-700">
            Event Timeline ({length(@events)} events)
          </h2>
          <%= if @events == [] do %>
            <p class="text-xs text-zinc-500">No events recorded.</p>
          <% else %>
            <ol class="space-y-2">
              <%= for entry <- @trace do %>
                <li
                  id={"assignment-event-#{entry.event.sequence}"}
                  class="rounded border px-3 py-2 text-xs"
                >
                  <div class="flex flex-wrap items-baseline gap-2">
                    <span class="font-mono text-zinc-400">
                      #{entry.event.sequence}
                    </span>
                    <span class={event_type_class(entry.event.type)}>
                      {entry.event.type}
                    </span>
                    <%= if entry.event.actor do %>
                      <span class="font-mono text-zinc-500">by {entry.event.actor}</span>
                    <% end %>
                    <span class="text-zinc-400 ml-auto">
                      {format_dt(entry.event.occurred_at)}
                    </span>
                  </div>
                  <div class="mt-1 flex items-center gap-2 text-zinc-600">
                    <%= if entry.before_state do %>
                      <span class="font-mono text-zinc-500">{entry.before_state}</span>
                      <span class="text-zinc-400">→</span>
                    <% end %>
                    <span class="font-mono">{entry.after_projection.state}</span>
                  </div>
                  <%= if entry.event.payload != %{} do %>
                    <details class="mt-1">
                      <summary class="cursor-pointer text-[10px] text-zinc-400">
                        payload
                      </summary>
                      <pre class="mt-1 text-[10px] font-mono bg-zinc-50 p-1 rounded overflow-auto">{inspect(entry.event.payload, pretty: true)}</pre>
                    </details>
                  <% end %>
                </li>
              <% end %>
            </ol>
          <% end %>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-medium text-zinc-700">Replay diagnostics</h2>
          <div class="rounded border bg-zinc-50 p-3 text-xs font-mono space-y-1">
            <div>events: {length(@events)}</div>
            <div>sequences: {inspect(Enum.map(@events, & &1.sequence))}</div>
            <div>gaps: {inspect(sequence_gaps(@events))}</div>
            <div>
              terminal: {if @projection,
                do: DevIDE.Assignments.StateMachine.terminal?(@projection.state),
                else: "—"}
            </div>
            <div>failed: {if @projection, do: Status.failed?(@projection.state), else: "—"}</div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp apply_assignment_notification(socket, %AssignmentNotification{} = n) do
    event = notification_event(n)
    before_state = socket.assigns[:projection] && socket.assigns.projection.state

    trace_entry = %{
      event: event,
      before_state: before_state,
      after_projection: n.projection
    }

    events = append_unique_event(socket.assigns[:events] || [], event)
    trace = (socket.assigns[:trace] || []) ++ [trace_entry]

    socket
    |> assign(:projection, n.projection)
    |> assign(:events, events)
    |> assign(:trace, trace)
    |> assign(:portfolio, Assignments.portfolio([n.projection]))
    |> maybe_refresh_proposals(n.assignment_id, n.event_type)
  end

  defp notification_event(%AssignmentNotification{event: %AssignmentEvent{} = event}), do: event

  defp notification_event(%AssignmentNotification{} = n) do
    %AssignmentEvent{
      assignment_id: n.assignment_id,
      sequence: n.sequence,
      type: n.event_type,
      occurred_at: n.occurred_at,
      payload: %{},
      actor: nil
    }
  end

  defp append_unique_event(events, %AssignmentEvent{sequence: sequence} = event) do
    if Enum.any?(events, &(&1.sequence == sequence)) do
      events
    else
      events ++ [event]
    end
  end

  defp maybe_refresh_proposals(socket, assignment_id, event_type)
       when event_type in @recovery_proposal_event_types do
    assign(socket, :proposals, Recovery.propose(assignment_id, proposed_by: "system"))
  end

  defp maybe_refresh_proposals(socket, _assignment_id, _event_type), do: socket

  defp refresh(socket, id) do
    projection =
      case Assignments.get(id) do
        {:ok, p} -> p
        :error -> nil
      end

    events = Assignments.replay(id)
    trace = build_trace(events)
    portfolio = if projection, do: Assignments.portfolio([projection]), else: empty_portfolio()
    proposals = Recovery.propose(id, proposed_by: "system")

    # Load fleet data
    lease =
      case Fleet.get_lease(id) do
        {:ok, l} -> l
        :error -> nil
      end

    runner =
      if lease do
        case Fleet.get_runner(lease.runner_id) do
          {:ok, r} -> r
          :error -> nil
        end
      else
        nil
      end

    execution_timeline = socket.assigns[:execution_timeline_items] || []

    output_chunks = load_output_chunks(id)

    socket
    |> assign(:assignment_id, id)
    |> assign(:projection, projection)
    |> assign(:events, events)
    |> assign(:trace, trace)
    |> assign(:portfolio, portfolio)
    |> assign(:proposals, proposals)
    |> assign(:approval_decisions, approvals_for_assignment(id))
    |> assign(:lease, lease)
    |> assign(:runner, runner)
    |> assign(:execution_timeline_items, execution_timeline)
    |> assign(:execution_timeline_count, length(execution_timeline))
    |> assign(:output_chunks_count, length(output_chunks))
    |> stream(:execution_timeline, execution_timeline, reset: true)
    |> stream(:output_chunks, output_chunks, reset: true)
  end

  @lease_topology_kinds [
    :lease_acquired,
    :lease_released,
    :lease_expired,
    :lease_renewed,
    :lease_revoked
  ]

  defp update_lease_topology(socket, %Notification{kind: kind} = n)
       when kind in @lease_topology_kinds do
    socket
    |> assign_lease_topology(n)
    |> assign_projection_lease(n)
  end

  defp update_lease_topology(socket, _notification), do: socket

  defp assign_lease_topology(socket, %Notification{kind: :lease_acquired, payload: payload}) do
    socket
    |> assign(:lease, payload[:lease] || payload["lease"])
    |> assign(:runner, payload[:runner] || payload["runner"])
  end

  defp assign_lease_topology(socket, %Notification{kind: :lease_renewed, payload: payload}) do
    assign(socket, :lease, payload[:lease] || payload["lease"])
  end

  defp assign_lease_topology(socket, %Notification{kind: kind})
       when kind in [:lease_released, :lease_expired, :lease_revoked] do
    socket
    |> assign(:lease, nil)
    |> assign(:runner, nil)
  end

  defp assign_projection_lease(socket, %Notification{kind: :lease_acquired, payload: payload}) do
    with %{} = projection <- socket.assigns[:projection],
         lease when not is_nil(lease) <- payload[:lease] || payload["lease"],
         runner when not is_nil(runner) <- payload[:runner] || payload["runner"] do
      assign(socket, :projection, %{
        projection
        | lease_owner: runner.id,
          lease_expires_at: lease.expires_at
      })
    else
      _ -> socket
    end
  end

  defp assign_projection_lease(socket, %Notification{kind: :lease_renewed, payload: payload}) do
    with %{} = projection <- socket.assigns[:projection],
         lease when not is_nil(lease) <- payload[:lease] || payload["lease"] do
      assign(socket, :projection, %{projection | lease_expires_at: lease.expires_at})
    else
      _ -> socket
    end
  end

  defp assign_projection_lease(socket, %Notification{kind: kind})
       when kind in [:lease_released, :lease_expired, :lease_revoked] do
    case socket.assigns[:projection] do
      %{} = projection ->
        assign(socket, :projection, %{projection | lease_owner: nil, lease_expires_at: nil})

      _ ->
        socket
    end
  end

  defp update_execution_timeline(socket, %Notification{kind: kind} = n)
       when kind in [
              :execution_started,
              :execution_completed,
              :execution_failed,
              :execution_abandoned
            ] do
    entry = execution_timeline_entry(kind, n)

    items =
      append_limited(
        socket.assigns[:execution_timeline_items] || [],
        entry,
        @max_execution_timeline_events
      )

    socket
    |> assign(:execution_timeline_items, items)
    |> assign(:execution_timeline_count, length(items))
    |> stream_insert(:execution_timeline, entry, at: -1, limit: -@max_execution_timeline_events)
  end

  defp update_execution_timeline(socket, _notification), do: socket

  defp maybe_append_output(socket, %Notification{kind: :output_chunk} = n) do
    chunk = output_chunk(n.payload, System.unique_integer([:positive, :monotonic]), "output-live")
    count = min((socket.assigns[:output_chunks_count] || 0) + 1, @max_output_chunks)

    socket
    |> assign(:output_chunks_count, count)
    |> stream_insert(:output_chunks, chunk, at: -1, limit: -@max_output_chunks)
  end

  defp maybe_append_output(socket, _notification), do: socket

  defp load_output_chunks(assignment_id) do
    case ExecutionProjectionStore.active_for_assignment(assignment_id) do
      {:ok, projection} ->
        projection.id
        |> OutputStream.chunks()
        |> normalize_output_chunks()

      :error ->
        assignment_id
        |> ExecutionProjectionStore.for_assignment()
        |> List.first()
        |> case do
          nil -> []
          projection -> stored_output_chunks(projection.id)
        end
    end
  end

  defp stored_output_chunks(execution_id) do
    case ArtifactStore.chunks(execution_id) do
      [] ->
        execution_id
        |> OutputStream.chunks()
        |> normalize_output_chunks()

      chunks ->
        chunks
        |> Enum.map(fn chunk ->
          %{stream: chunk.stream, chunk: chunk.data, timestamp: chunk.timestamp}
        end)
        |> normalize_output_chunks()
    end
  end

  defp normalize_output_chunks(chunks) do
    chunks
    |> tail(@max_output_chunks)
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} -> output_chunk(chunk, index, "output-loaded") end)
  end

  defp output_chunk(payload, index, prefix) do
    payload = if is_map(payload), do: payload, else: %{}

    %{
      id: "#{prefix}-#{index}",
      stream: payload[:stream] || payload["stream"] || "unknown",
      chunk: payload[:chunk] || payload["chunk"] || payload[:data] || payload["data"] || "",
      timestamp: payload[:timestamp] || payload["timestamp"]
    }
  end

  defp execution_timeline_entry(kind, %Notification{} = n) do
    %{
      id: "execution-#{System.unique_integer([:positive, :monotonic])}",
      kind: kind,
      runner_id: n.runner_id,
      execution_id: n.execution_id,
      payload: n.payload,
      occurred_at: n.occurred_at
    }
  end

  defp append_limited(items, item, limit) do
    items = tail(items, limit - 1)
    items ++ [item]
  end

  defp tail(items, limit) when length(items) <= limit, do: items
  defp tail(items, limit), do: Enum.drop(items, length(items) - limit)

  defp build_trace(events) do
    traces = Reducer.trace(events)

    Enum.map(traces, fn {event, before, after_proj} ->
      %{event: event, before_state: before, after_projection: after_proj}
    end)
  end

  defp empty_portfolio do
    %{
      total: 0,
      requested: 0,
      queued: 0,
      claimed: 0,
      running: 0,
      completed: 0,
      failed: 0,
      abandoned: 0,
      expired: 0,
      terminal: 0,
      in_progress: 0
    }
  end

  defp portfolio_summary(portfolio) do
    [
      "total: #{portfolio.total}",
      "in_progress: #{portfolio.in_progress}",
      "terminal: #{portfolio.terminal}"
    ]
    |> Enum.join(" · ")
  end

  defp state_badge_class(state) do
    case Status.status_class(state) do
      :running -> "font-mono text-amber-700 font-medium"
      :succeeded -> "font-mono text-green-700 font-medium"
      :failed -> "font-mono text-red-700 font-medium"
      :timed_out -> "font-mono text-purple-700 font-medium"
      _ -> "font-mono text-zinc-500"
    end
  end

  defp event_type_class(:created), do: "font-mono text-zinc-600 font-medium"
  defp event_type_class(:claimed), do: "font-mono text-amber-600 font-medium"
  defp event_type_class(:started), do: "font-mono text-blue-600 font-medium"
  defp event_type_class(:completed), do: "font-mono text-green-600 font-medium"
  defp event_type_class(:failed), do: "font-mono text-red-600 font-medium"
  defp event_type_class(:abandoned), do: "font-mono text-purple-600 font-medium"
  defp event_type_class(:expired), do: "font-mono text-orange-600 font-medium"
  defp event_type_class(_), do: "font-mono text-zinc-500"

  defp execution_kind_class(:execution_started),
    do: "rounded bg-blue-100 text-blue-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp execution_kind_class(:execution_completed),
    do: "rounded bg-green-100 text-green-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp execution_kind_class(:execution_failed),
    do: "rounded bg-red-100 text-red-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp execution_kind_class(:execution_abandoned),
    do: "rounded bg-purple-100 text-purple-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp execution_kind_class(_), do: "rounded bg-zinc-100 text-zinc-500 px-1.5 py-0.5 text-[10px]"

  defp output_stream_class("stderr"), do: "text-red-400"
  defp output_stream_class("stdout"), do: "text-zinc-300"
  defp output_stream_class(_), do: "text-zinc-400"

  defp approvals_for_assignment(assignment_id) do
    Approvals.list()
    |> Enum.filter(&(&1.target_type == "assignment" and &1.target_ref == assignment_id))
  end

  defp latest_approval(approvals, proposal) do
    Enum.find(approvals, &(&1.action == Atom.to_string(proposal.kind)))
  end

  defp requested_approval(approvals, proposal) do
    Enum.find(
      approvals,
      &(&1.action == Atom.to_string(proposal.kind) and &1.status == "requested")
    )
  end

  defp granted_approval(approvals, proposal) do
    Enum.find(
      approvals,
      &(&1.action == Atom.to_string(proposal.kind) and &1.status == "granted")
    )
  end

  defp operator_id(socket) do
    (socket.assigns.current_user && socket.assigns.current_user.id) || "operator"
  end

  defp recovery_actor(socket) do
    user = socket.assigns[:current_user] || %{}

    %{
      email: Map.get(user, :email),
      username: Map.get(user, :username) || Map.get(user, :id),
      role: Map.get(user, :role),
      id: Map.get(user, :id)
    }
  end

  defp recovery_denied_message, do: "You are not authorized to perform this recovery action."

  defp do_grant_recovery_approval(socket, approval_id) do
    case Fleet.grant_approval(approval_id, actor_id: operator_id(socket)) do
      {:ok, _approval} ->
        {:noreply,
         socket
         |> put_flash(:info, "Recovery approval granted.")
         |> refresh(socket.assigns.assignment_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approval grant failed: #{inspect(reason)}")}
    end
  end

  defp risk_level_badge(:safe),
    do: "rounded bg-green-100 text-green-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp risk_level_badge(:moderate),
    do: "rounded bg-amber-100 text-amber-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp risk_level_badge(:high),
    do: "rounded bg-red-100 text-red-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp risk_level_border(:safe), do: "border-green-200"
  defp risk_level_border(:moderate), do: "border-amber-200"
  defp risk_level_border(:high), do: "border-red-200"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp sequence_gaps(events) when length(events) < 2, do: []

  defp sequence_gaps(events) do
    sequences = Enum.map(events, & &1.sequence) |> Enum.sort()

    sequences
    |> Enum.zip(Enum.drop(sequences, 1))
    |> Enum.filter(fn {a, b} -> b - a > 1 end)
    |> Enum.map(fn {a, b} -> {a + 1, b - 1} end)
  end
end
