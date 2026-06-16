defmodule DevIdeWeb.FleetLive.RunnerShow do
  @moduledoc """
  Runner diagnostics page for the remote fleet substrate.
  """

  use DevIdeWeb, :live_view

  alias DevIDE.Fleet
  alias DevIDE.Fleet.Notification

  @refresh_debounce_ms 400

  @impl true
  def mount(%{"id" => runner_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DevIde.PubSub, "fleet")
      Phoenix.PubSub.subscribe(DevIde.PubSub, "fleet:runners:#{runner_id}")
    end

    socket =
      socket
      |> assign_new(:current_scope, fn -> nil end)
      |> assign(:runner_refresh_timer, nil)

    {:ok, refresh(socket, runner_id)}
  end

  @impl true
  def handle_info({_source, %Notification{kind: kind}}, socket)
      when kind in [:output_chunk, :telemetry] do
    {:noreply, socket}
  end

  def handle_info({_source, %Notification{}}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:runner_refresh, socket) do
    socket = assign(socket, :runner_refresh_timer, nil)
    {:noreply, refresh(socket, socket.assigns.runner_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh(socket, socket.assigns.runner_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-6xl p-6 space-y-6">
        <header class="flex items-center justify-between">
          <div>
            <.link navigate={~p"/fleet"} class="text-sm text-blue-700 hover:underline">
              ← Fleet
            </.link>
            <h1 class="text-2xl font-semibold">Runner {short_id(@runner_id)}</h1>
            <p class="text-xs text-zinc-500 font-mono">
              identity · leases · executions · dossier links
            </p>
          </div>
          <button phx-click="refresh" class="text-xs rounded border px-2 py-1 hover:bg-zinc-50">
            Refresh
          </button>
        </header>

        <%= if @diagnostics do %>
          <section id="runner-identity" class="rounded border p-4 space-y-3">
            <h2 class="text-sm font-medium text-zinc-700">Identity</h2>
            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
              <dt class="text-zinc-500">id</dt>
              <dd class="font-mono">{@diagnostics.runner.id}</dd>
              <dt class="text-zinc-500">hostname</dt>
              <dd>{@diagnostics.runner.hostname}</dd>
              <dt class="text-zinc-500">registry state</dt>
              <dd>
                <span class={state_badge(@diagnostics.runner.state)}>
                  {@diagnostics.runner.state}
                </span>
              </dd>
              <dt class="text-zinc-500">trust state</dt>
              <dd>
                <span class={trust_badge(trust_state(@diagnostics.identity))}>
                  {trust_state(@diagnostics.identity)}
                </span>
              </dd>
              <dt class="text-zinc-500">last heartbeat</dt>
              <dd class="font-mono">{format_rel(@diagnostics.runner.last_heartbeat_at)}</dd>
              <dt class="text-zinc-500">capabilities</dt>
              <dd class="flex flex-wrap gap-1">
                <%= for capability <- @diagnostics.runner.capabilities || [] do %>
                  <span class="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px]">
                    {capability}
                  </span>
                <% end %>
              </dd>
            </dl>
          </section>

          <section id="runner-active-leases" class="rounded border p-4 space-y-3">
            <h2 class="text-sm font-medium text-zinc-700">Active Leases</h2>
            <%= if @diagnostics.active_leases == [] do %>
              <p class="text-xs text-zinc-500">No active leases.</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full text-xs">
                  <thead>
                    <tr class="text-left text-zinc-500 border-b">
                      <th class="pb-1 pr-3">Assignment</th>
                      <th class="pb-1 pr-3">Lease</th>
                      <th class="pb-1 pr-3">Expires</th>
                      <th class="pb-1 pr-3">Dossier</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-100">
                    <%= for lease <- @diagnostics.active_leases do %>
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
                          {short_id(lease.id)}
                        </td>
                        <td class="py-1.5 pr-3 font-mono text-zinc-500">
                          {format_rel(lease.expires_at)}
                        </td>
                        <td class="py-1.5 pr-3">
                          <a
                            href={"#runner-dossier-#{lease.assignment_id}"}
                            class="text-blue-700 hover:underline"
                          >
                            dossier
                          </a>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <section id="runner-current-execution" class="rounded border p-4 space-y-3">
            <h2 class="text-sm font-medium text-zinc-700">Current Execution</h2>
            <%= if @diagnostics.current_execution do %>
              <.execution_row execution={@diagnostics.current_execution} />
            <% else %>
              <p class="text-xs text-zinc-500">No active execution.</p>
            <% end %>
          </section>

          <section id="runner-executions" class="rounded border p-4 space-y-3">
            <h2 class="text-sm font-medium text-zinc-700">Execution Timeline Links</h2>
            <%= if @diagnostics.executions == [] do %>
              <p class="text-xs text-zinc-500">No executions observed for this runner.</p>
            <% else %>
              <div class="divide-y divide-zinc-100">
                <%= for execution <- @diagnostics.executions do %>
                  <.execution_row execution={execution} />
                <% end %>
              </div>
            <% end %>
          </section>

          <section id="runner-recent-failures" class="rounded border p-4 space-y-3">
            <h2 class="text-sm font-medium text-zinc-700">Recent Failures</h2>
            <%= if @diagnostics.recent_failures == [] do %>
              <p class="text-xs text-zinc-500">No recent failures.</p>
            <% else %>
              <div class="divide-y divide-zinc-100">
                <%= for failure <- @diagnostics.recent_failures do %>
                  <div class="py-2 text-xs">
                    <div class="flex items-center justify-between gap-3">
                      <span class="font-mono text-red-700">{failure.state}</span>
                      <span class="font-mono text-zinc-400">{format_rel(failure.occurred_at)}</span>
                    </div>
                    <div class="mt-1 flex flex-wrap gap-2 font-mono text-[10px] text-zinc-500">
                      <.link
                        navigate={~p"/assignments/#{failure.assignment_id}"}
                        class="text-blue-700 hover:underline"
                      >
                        assignment {short_id(failure.assignment_id)}
                      </.link>
                      <%= if failure.execution_id do %>
                        <a
                          href={"#execution-#{failure.execution_id}"}
                          class="text-blue-700 hover:underline"
                        >
                          execution {short_id(failure.execution_id)}
                        </a>
                      <% end %>
                      <a
                        href={"#runner-dossier-#{failure.assignment_id}"}
                        class="text-blue-700 hover:underline"
                      >
                        dossier
                      </a>
                    </div>
                    <p class="mt-1 text-zinc-600">{failure.reason || "—"}</p>
                  </div>
                <% end %>
              </div>
            <% end %>
          </section>

          <%= for {assignment_id, dossier} <- @diagnostics.dossiers do %>
            <section id={"runner-dossier-#{assignment_id}"} class="rounded border p-4 space-y-2">
              <h2 class="text-sm font-medium text-zinc-700">
                Dossier {short_id(assignment_id)}
              </h2>
              <%= if dossier do %>
                <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
                  <dt class="text-zinc-500">workspace</dt>
                  <dd class="font-mono">{dossier.workspace_id}</dd>
                  <dt class="text-zinc-500">executions</dt>
                  <dd class="font-mono">{length(dossier.executions)}</dd>
                  <dt class="text-zinc-500">artifacts</dt>
                  <dd class="font-mono">{length(dossier.artifacts)}</dd>
                  <dt class="text-zinc-500">failures</dt>
                  <dd class="font-mono">{length(dossier.failures)}</dd>
                </dl>
              <% else %>
                <p class="text-xs text-zinc-500">Dossier is not available.</p>
              <% end %>
            </section>
          <% end %>
        <% else %>
          <section class="rounded border p-4">
            <p class="text-sm text-zinc-600">Runner not found.</p>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :execution, :map, required: true

  def execution_row(assigns) do
    ~H"""
    <div id={"execution-#{@execution.id}"} class="py-2 text-xs">
      <div class="flex items-center justify-between gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class={state_badge(@execution.state)}>{@execution.state}</span>
          <span class="font-mono text-zinc-700">execution {short_id(@execution.id)}</span>
        </div>
        <span class="font-mono text-zinc-400">{format_rel(@execution.started_at)}</span>
      </div>
      <div class="mt-1 flex flex-wrap gap-2 font-mono text-[10px] text-zinc-500">
        <.link
          navigate={~p"/assignments/#{@execution.assignment_id}"}
          class="text-blue-700 hover:underline"
        >
          assignment {short_id(@execution.assignment_id)}
        </.link>
        <a href={"#execution-#{@execution.id}"} class="text-blue-700 hover:underline">
          execution
        </a>
        <a href={"#runner-dossier-#{@execution.assignment_id}"} class="text-blue-700 hover:underline">
          dossier
        </a>
        <span>lease {short_id(@execution.lease_id)}</span>
      </div>
    </div>
    """
  end

  defp schedule_refresh(socket) do
    if debounce_ms() == 0 do
      refresh(socket, socket.assigns.runner_id)
    else
      if socket.assigns[:runner_refresh_timer] do
        Process.cancel_timer(socket.assigns.runner_refresh_timer)
      end

      ref = Process.send_after(self(), :runner_refresh, debounce_ms())
      assign(socket, :runner_refresh_timer, ref)
    end
  end

  defp debounce_ms do
    Application.get_env(:dev_ide, :fleet_live_refresh_debounce_ms, @refresh_debounce_ms)
  end

  defp refresh(socket, runner_id) do
    diagnostics =
      case Fleet.runner_diagnostics(runner_id) do
        {:ok, diagnostics} -> diagnostics
        {:error, _reason} -> nil
      end

    socket
    |> assign(:runner_id, runner_id)
    |> assign(:diagnostics, diagnostics)
  end

  defp trust_state(nil), do: :unknown
  defp trust_state(identity), do: identity.trust_state

  defp state_badge(:online),
    do: "rounded bg-green-100 text-green-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp state_badge(:idle),
    do: "rounded bg-blue-100 text-blue-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp state_badge(:busy),
    do: "rounded bg-amber-100 text-amber-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp state_badge(:failed),
    do: "rounded bg-red-100 text-red-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp state_badge(:completed),
    do: "rounded bg-green-100 text-green-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp state_badge(_),
    do: "rounded bg-zinc-100 text-zinc-500 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_badge(:authorized),
    do: "rounded bg-green-100 text-green-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_badge(:maintenance),
    do: "rounded bg-purple-100 text-purple-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_badge(:draining),
    do: "rounded bg-orange-100 text-orange-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_badge(:revoked),
    do: "rounded bg-red-100 text-red-700 px-1.5 py-0.5 text-[10px] font-medium"

  defp trust_badge(_),
    do: "rounded bg-zinc-100 text-zinc-500 px-1.5 py-0.5 text-[10px] font-medium"

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
end
