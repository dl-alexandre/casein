defmodule DevIdeWeb.AssignmentLive.Index do
  @moduledoc """
  Read-only LiveView for browsing orchestrated assignments.

  This is intentionally a status/table surface — no execution,
  no retries, no autonomous planning.
  """

  use DevIdeWeb, :live_view

  alias DevIDE.Assignments
  alias DevIDE.Assignments.StateMachine
  alias DevIDE.Runs.Status

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: DevIDE.Assignments.subscribe()
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info({DevIDE.Assignments, _notification}, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("filter_state", %{"state" => ""}, socket) do
    {:noreply, assign(socket, :filter_state, nil) |> refresh()}
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply, assign(socket, :filter_state, state) |> refresh()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-6xl p-6 space-y-4">
        <header class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold">Assignments</h1>
            <p class="text-xs text-zinc-500 font-mono">
              {portfolio_summary(@portfolio)}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.form for={%{}} phx-change="filter_state" class="inline-flex">
              <select name="state" class="border rounded px-2 py-1 text-xs">
                <option value="" selected={is_nil(@filter_state)}>all states</option>
                <%= for s <- StateMachine.states() do %>
                  <option value={s} selected={@filter_state == s}>{s}</option>
                <% end %>
              </select>
            </.form>
            <button
              phx-click="refresh"
              class="text-xs rounded border px-2 py-1 hover:bg-zinc-50"
            >
              Refresh
            </button>
          </div>
        </header>

        <%= if @assignments == [] do %>
          <p class="text-sm text-zinc-500">No assignments found.</p>
        <% else %>
          <div class="overflow-auto">
            <table class="w-full text-xs">
              <thead>
                <tr class="border-b text-left text-zinc-500">
                  <th class="px-2 py-1">ID</th>
                  <th class="px-2 py-1">Workspace</th>
                  <th class="px-2 py-1">Run</th>
                  <th class="px-2 py-1">State</th>
                  <th class="px-2 py-1">Lease owner</th>
                  <th class="px-2 py-1">Expires</th>
                  <th class="px-2 py-1">Claimed</th>
                  <th class="px-2 py-1">Completed</th>
                </tr>
              </thead>
              <tbody class="divide-y">
                <%= for a <- @assignments do %>
                  <tr class="hover:bg-zinc-50">
                    <td class="px-2 py-1.5 font-mono text-zinc-700">
                      <.link navigate={~p"/assignments/#{a.id}"} class="hover:underline">
                        {a.id}
                      </.link>
                    </td>
                    <td class="px-2 py-1.5 font-mono">{a.workspace_id}</td>
                    <td class="px-2 py-1.5 font-mono text-zinc-500">{a.run_id || "—"}</td>
                    <td class="px-2 py-1.5">
                      <span class={state_badge_class(a.state)}>
                        {a.state}
                      </span>
                    </td>
                    <td class="px-2 py-1.5 font-mono text-zinc-500">{a.lease_owner || "—"}</td>
                    <td class="px-2 py-1.5 font-mono text-zinc-500">
                      <%= if a.lease_expires_at do %>
                        {format_dt(a.lease_expires_at)}
                      <% else %>
                        —
                      <% end %>
                    </td>
                    <td class="px-2 py-1.5 font-mono text-zinc-500">
                      <%= if a.claimed_at do %>
                        {format_dt(a.claimed_at)}
                      <% else %>
                        —
                      <% end %>
                    </td>
                    <td class="px-2 py-1.5 font-mono text-zinc-500">
                      <%= if a.completed_at do %>
                        {format_dt(a.completed_at)}
                      <% else %>
                        —
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp refresh(socket) do
    filter_state = socket.assigns[:filter_state]

    assignments =
      if filter_state do
        Assignments.list(state: filter_state)
      else
        Assignments.list()
      end

    portfolio = Assignments.portfolio(assignments)

    socket
    |> assign(:assignments, assignments)
    |> assign(:portfolio, portfolio)
  end

  defp portfolio_summary(portfolio) do
    [
      "total: #{portfolio.total}",
      "in_progress: #{portfolio.in_progress}",
      "terminal: #{portfolio.terminal}",
      "completed: #{portfolio.completed}",
      "failed: #{portfolio.failed}",
      "expired: #{portfolio.expired}",
      "abandoned: #{portfolio.abandoned}"
    ]
    |> Enum.join(" · ")
  end

  defp state_badge_class(state) do
    case Status.status_class(state) do
      :running -> "text-amber-700 font-medium"
      :succeeded -> "text-green-700 font-medium"
      :failed -> "text-red-700 font-medium"
      :timed_out -> "text-purple-700 font-medium"
      _ -> "text-zinc-500"
    end
  end

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
end
