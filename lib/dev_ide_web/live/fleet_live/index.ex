defmodule DevIdeWeb.FleetLive.Index do
  @moduledoc """
  Live fleet dashboard.

  Shows:
    * Fleet snapshot (total runners, online, busy, active leases)
    * Queue and scheduler plan for pending assignments
    * Runner list with state, capabilities, last heartbeat
    * Runner identity trust state
    * Active lease list with runner ↔ assignment topology
    * Recent operator notifications
    * Real-time updates via PubSub
  """

  use DevIdeWeb, :live_view

  alias DevIDE.Fleet
  alias DevIDE.Fleet.Notification

  @refresh_debounce_ms 400

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(DevIde.PubSub, "fleet")

    socket =
      socket
      |> assign_new(:current_scope, fn -> nil end)
      |> assign(:fleet_refresh_timer, nil)

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info({DevIDE.Fleet.Registry, _notification}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({DevIDE.Fleet.LocalRunnerAdapter, %Notification{kind: kind}}, socket)
      when kind in [:output_chunk, :telemetry] do
    {:noreply, socket}
  end

  def handle_info({DevIDE.Fleet.LocalRunnerAdapter, _notification}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:fleet_refresh, socket) do
    {:noreply, socket |> assign(:fleet_refresh_timer, nil) |> refresh()}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, refresh(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <header class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold">Fleet</h1>
            <p class="text-xs text-zinc-500 font-mono">
              {@snapshot.total_runners} runners · {@snapshot.online} online · {@snapshot.busy} busy · {@snapshot.active_leases} active leases
            </p>
          </div>
          <button phx-click="refresh" class="text-xs rounded border px-2 py-1 hover:bg-zinc-50">
            Refresh
          </button>
        </header>

        <section class="rounded border p-4 space-y-3">
          <div class="flex items-center justify-between gap-3">
            <div>
              <h2 class="text-sm font-medium text-zinc-700">Scheduler</h2>
              <p class="text-xs text-zinc-500 font-mono">
                {@scheduler_plan.queue_depth} queued · {@scheduler_plan.active_leases} active leases · generated {format_rel(
                  @scheduler_plan.generated_at
                )}
              </p>
            </div>
            <div class="text-right text-xs text-zinc-500">
              <div class="font-mono">{map_size(@scheduler_plan.runner_pools)} pools</div>
              <div>{map_size(@scheduler_plan.active_concurrency_groups)} concurrency groups</div>
            </div>
          </div>

          <%= if @scheduler_plan.entries == [] do %>
            <p class="text-xs text-zinc-500">No queued assignments.</p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="w-full text-xs">
                <thead>
                  <tr class="text-left text-zinc-500 border-b">
                    <th class="pb-1 pr-3">Assignment</th>
                    <th class="pb-1 pr-3">Priority</th>
                    <th class="pb-1 pr-3">Pool</th>
                    <th class="pb-1 pr-3">Workspace</th>
                    <th class="pb-1 pr-3">Selected Runner</th>
                    <th class="pb-1 pr-3">Eligible</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                  <%= for entry <- @scheduler_plan.entries do %>
                    <tr>
                      <td class="py-1.5 pr-3 font-mono">
                        <.link
                          navigate={~p"/assignments/#{entry.assignment_id}"}
                          class="text-blue-700 hover:underline"
                        >
                          {short_id(entry.assignment_id)}
                        </.link>
                      </td>
                      <td class="py-1.5 pr-3">
                        <span class="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px]">
                          {entry.priority}
                        </span>
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-500">
                        {entry.runner_pool || "default"}
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-500">
                        {entry.workspace_affinity || "any"}
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-600">
                        {short_id(entry.selected_runner)}
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-500">
                        {runner_list(entry.eligible_runners)}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="rounded border p-4 space-y-3">
          <h2 class="text-sm font-medium text-zinc-700">Runners</h2>
          <%= if @runners == [] do %>
            <p class="text-xs text-zinc-500">No runners registered.</p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="w-full text-xs">
                <thead>
                  <tr class="text-left text-zinc-500 border-b">
                    <th class="pb-1 pr-3">ID</th>
                    <th class="pb-1 pr-3">Hostname</th>
                    <th class="pb-1 pr-3">State</th>
                    <th class="pb-1 pr-3">Capabilities</th>
                    <th class="pb-1 pr-3">Active Assignment</th>
                    <th class="pb-1 pr-3">Last Heartbeat</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                  <%= for runner <- @runners do %>
                    <tr class="group">
                      <td class="py-1.5 pr-3 font-mono text-zinc-600">
                        <.link
                          navigate={~p"/fleet/runners/#{runner.id}"}
                          class="text-blue-700 hover:underline"
                        >
                          {short_id(runner.id)}
                        </.link>
                      </td>
                      <td class="py-1.5 pr-3">
                        <.link
                          navigate={~p"/fleet/runners/#{runner.id}"}
                          class="text-blue-700 hover:underline"
                        >
                          {runner.hostname}
                        </.link>
                      </td>
                      <td class="py-1.5 pr-3">
                        <span class={runner_state_badge(runner.state)}>
                          {runner.state}
                        </span>
                      </td>
                      <td class="py-1.5 pr-3">
                        <div class="flex flex-wrap gap-1">
                          <%= for cap <- runner.capabilities || [] do %>
                            <span class="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px]">{cap}</span>
                          <% end %>
                        </div>
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-500">
                        <%= if runner.active_assignment_id do %>
                          <.link
                            navigate={~p"/assignments/#{runner.active_assignment_id}"}
                            class="text-blue-700 hover:underline"
                          >
                            {short_id(runner.active_assignment_id)}
                          </.link>
                        <% else %>
                          —
                        <% end %>
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-400">
                        <%= if runner.last_heartbeat_at do %>
                          {format_rel(runner.last_heartbeat_at)}
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
        </section>

        <section class="rounded border p-4 space-y-3">
          <h2 class="text-sm font-medium text-zinc-700">Runner Identities</h2>
          <%= if @runner_identities == [] do %>
            <p class="text-xs text-zinc-500">No runner identities registered.</p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="w-full text-xs">
                <thead>
                  <tr class="text-left text-zinc-500 border-b">
                    <th class="pb-1 pr-3">ID</th>
                    <th class="pb-1 pr-3">Hostname</th>
                    <th class="pb-1 pr-3">Trust</th>
                    <th class="pb-1 pr-3">Transports</th>
                    <th class="pb-1 pr-3">Updated</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                  <%= for identity <- @runner_identities do %>
                    <tr>
                      <td class="py-1.5 pr-3 font-mono text-zinc-600">{short_id(identity.id)}</td>
                      <td class="py-1.5 pr-3">{identity.hostname}</td>
                      <td class="py-1.5 pr-3">
                        <span class={trust_state_badge(identity.trust_state)}>
                          {identity.trust_state}
                        </span>
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-500">
                        {Enum.join(identity.manifest.transports || [], ", ")}
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-400">
                        {format_rel(identity.updated_at)}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="rounded border p-4 space-y-3">
          <h2 class="text-sm font-medium text-zinc-700">Active Leases</h2>
          <%= if @active_leases == [] do %>
            <p class="text-xs text-zinc-500">No active leases.</p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="w-full text-xs">
                <thead>
                  <tr class="text-left text-zinc-500 border-b">
                    <th class="pb-1 pr-3">Assignment</th>
                    <th class="pb-1 pr-3">Runner</th>
                    <th class="pb-1 pr-3">Acquired</th>
                    <th class="pb-1 pr-3">Expires</th>
                    <th class="pb-1 pr-3">Remaining</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                  <%= for lease <- @active_leases do %>
                    <tr>
                      <td class="py-1.5 pr-3 font-mono">
                        <.link
                          navigate={~p"/assignments/#{lease.assignment_id}"}
                          class="text-blue-700 hover:underline"
                        >
                          {short_id(lease.assignment_id)}
                        </.link>
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-500">
                        {short_id(lease.runner_id)}
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-400">
                        {format_rel(lease.acquired_at)}
                      </td>
                      <td class="py-1.5 pr-3 font-mono text-zinc-400">
                        {format_rel(lease.expires_at)}
                      </td>
                      <td class="py-1.5 pr-3">
                        <span class={lease_remaining_class(lease)}>
                          {lease_remaining_text(lease)}
                        </span>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="rounded border p-4 space-y-3">
          <h2 class="text-sm font-medium text-zinc-700">Recent Operator Notifications</h2>
          <%= if @operator_notifications == [] do %>
            <p class="text-xs text-zinc-500">No recent notifications.</p>
          <% else %>
            <div class="divide-y divide-zinc-100">
              <%= for notification <- @operator_notifications do %>
                <div class="py-2 text-xs">
                  <div class="flex items-center justify-between gap-3">
                    <span class="font-medium text-zinc-700">{notification.message}</span>
                    <span class="font-mono text-zinc-400">
                      {format_rel(notification.occurred_at)}
                    </span>
                  </div>
                  <div class="mt-1 flex flex-wrap gap-2 font-mono text-[10px] text-zinc-500">
                    <span>{notification.kind}</span>
                    <span>assignment {short_id(notification.assignment_id)}</span>
                    <span>execution {short_id(notification.execution_id)}</span>
                    <span>runner {short_id(notification.runner_id)}</span>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp schedule_refresh(socket) do
    if debounce_ms() == 0 do
      refresh(socket)
    else
      if socket.assigns[:fleet_refresh_timer] do
        Process.cancel_timer(socket.assigns.fleet_refresh_timer)
      end

      ref = Process.send_after(self(), :fleet_refresh, debounce_ms())
      assign(socket, :fleet_refresh_timer, ref)
    end
  end

  defp debounce_ms do
    Application.get_env(:dev_ide, :fleet_live_refresh_debounce_ms, @refresh_debounce_ms)
  end

  defp refresh(socket) do
    scheduler_plan = Fleet.scheduler_plan()

    socket
    |> assign(:snapshot, Fleet.snapshot())
    |> assign(:scheduler_plan, scheduler_plan)
    |> assign(:runners, Fleet.list_runners() |> Enum.sort_by(& &1.hostname))
    |> assign(:runner_identities, Fleet.runner_identities())
    |> assign(:operator_notifications, Fleet.operator_notifications(limit: 10))
    |> assign(
      :active_leases,
      Fleet.active_leases() |> Enum.sort_by(& &1.acquired_at, {:desc, DateTime})
    )
  end

  defp runner_state_badge(:online),
    do: "rounded bg-green-100 text-green-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp runner_state_badge(:idle),
    do: "rounded bg-blue-100 text-blue-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp runner_state_badge(:busy),
    do: "rounded bg-amber-100 text-amber-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp runner_state_badge(:offline),
    do: "rounded bg-zinc-100 text-zinc-500 px-1.5 py-0.5 text-[10px] font-medium"

  defp runner_state_badge(:maintenance),
    do: "rounded bg-purple-100 text-purple-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp runner_state_badge(:draining),
    do: "rounded bg-orange-100 text-orange-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp runner_state_badge(_), do: "rounded bg-zinc-100 text-zinc-500 px-1.5 py-0.5 text-[10px]"

  defp trust_state_badge(:authorized),
    do: "rounded bg-green-100 text-green-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_state_badge(:maintenance),
    do: "rounded bg-purple-100 text-purple-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_state_badge(:draining),
    do: "rounded bg-orange-100 text-orange-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_state_badge(:revoked),
    do: "rounded bg-red-100 text-red-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_state_badge(_), do: "rounded bg-zinc-100 text-zinc-500 px-1.5 py-0.5 text-[10px]"

  defp lease_remaining_class(lease) do
    now = DateTime.utc_now()
    seconds = DateTime.diff(lease.expires_at, now)

    cond do
      seconds < 60 -> "font-mono text-red-600 font-medium"
      seconds < 300 -> "font-mono text-amber-600"
      true -> "font-mono text-green-600"
    end
  end

  defp lease_remaining_text(lease) do
    now = DateTime.utc_now()
    seconds = DateTime.diff(lease.expires_at, now)

    if seconds > 0 do
      minutes = div(seconds, 60)
      rem = rem(seconds, 60)
      "#{minutes}m #{rem}s"
    else
      "expired"
    end
  end

  defp format_rel(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      seconds < -3600 -> "in #{div(abs(seconds), 3600)}h"
      seconds < -60 -> "in #{div(abs(seconds), 60)}m"
      seconds < 0 -> "in #{abs(seconds)}s"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3600)}h ago"
    end
  end

  defp format_rel(_), do: "—"

  defp short_id(nil), do: "—"

  defp short_id(id) when is_binary(id) do
    if String.length(id) > 8, do: String.slice(id, 0, 8) <> "…", else: id
  end

  defp short_id(id), do: to_string(id)

  defp runner_list([]), do: "none"

  defp runner_list(runner_ids) do
    runner_ids
    |> Enum.take(3)
    |> Enum.map_join(", ", &short_id/1)
    |> then(fn text ->
      if length(runner_ids) > 3,
        do: text <> " +" <> Integer.to_string(length(runner_ids) - 3),
        else: text
    end)
  end
end
