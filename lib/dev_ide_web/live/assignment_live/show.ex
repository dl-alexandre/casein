defmodule DevIdeWeb.AssignmentLive.Show do
  @moduledoc """
  Read-only timeline and inspection view for a single assignment.

  Shows:
    * Assignment projection summary
    * Event stream with sequence numbers
    * Reducer trace (state transition per event)
    * Payload inspection

  No editing. No mutation. Pure introspection.
  """

  use DevIdeWeb, :live_view

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Reducer
  alias DevIDE.Runs.Status

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: DevIDE.Assignments.subscribe(id)
    {:ok, refresh(socket, id)}
  end

  @impl true
  def handle_info({DevIDE.Assignments, _notification}, socket) do
    {:noreply, refresh(socket, socket.assigns.assignment_id)}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, refresh(socket, socket.assigns.assignment_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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

  defp refresh(socket, id) do
    projection =
      case Assignments.get(id) do
        {:ok, p} -> p
        :error -> nil
      end

    events = Assignments.replay(id)
    trace = build_trace(events)
    portfolio = if projection, do: Assignments.portfolio([projection]), else: empty_portfolio()

    socket
    |> assign(:assignment_id, id)
    |> assign(:projection, projection)
    |> assign(:events, events)
    |> assign(:trace, trace)
    |> assign(:portfolio, portfolio)
  end

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
