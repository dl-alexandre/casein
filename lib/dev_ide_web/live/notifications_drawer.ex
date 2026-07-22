defmodule DevIdeWeb.NotificationsDrawer do
  @moduledoc """
  Global notifications drawer: bell + unread badge entry point rendered in the
  workspace cockpit header, opening a right-side drawer with the durable
  notification inbox (list, mark read / resolve / mute, mark-all-read),
  delivery preferences, and the admin push-device table.

  Rendering carried over from the removed `/notifications` full-page LiveView,
  restyled to the cockpit's drawer conventions (see `Show.AuditDrawer`). State
  and events live in `DevIdeWeb.NotificationsDrawerEvents`.
  """

  use DevIdeWeb, :html

  alias DevIdeWeb.WorkspaceLive.Show.AgentApprovals

  @event_types [
    {"Needs review", "needs_review"},
    {"Policy blocked", "policy_blocked"},
    {"Agent blocked", "agent_blocked"},
    {"Run timed out", "run_timed_out"}
  ]

  @channels [
    {"In app", "in_app"},
    {"Push", "push"},
    {"Mobile", "mobile"},
    {"Browser", "browser"},
    {"Digest", "digest"}
  ]

  attr :id, :string, default: "notifications-bell"
  attr :unread_count, :integer, required: true
  attr :deploy_failure, :any, default: nil
  attr :deploy_in_progress, :any, default: nil
  attr :update_available, :boolean, default: false
  attr :deploy_drift, :any, default: nil
  attr :update_commits_behind, :integer, default: 0

  def notifications_bell(assigns) do
    assigns =
      assigns
      |> assign(:deploy_severity, deploy_severity(assigns))
      |> assign(:deploy_signal?, deploy_signal?(assigns))
      |> assign(:bell_alert?, assigns.unread_count > 0 or deploy_signal?(assigns))

    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="notifications:toggle"
      class="relative inline-flex items-center justify-center rounded border border-base-300 p-1 text-sm text-base-content/80 hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:p-0"
      title={bell_title(assigns)}
      aria-label={bell_aria_label(assigns)}
    >
      <.icon
        name={if(@bell_alert?, do: "hero-bell-alert", else: "hero-bell")}
        class={[
          "size-4",
          @bell_alert? && @deploy_signal? && @unread_count == 0 && @deploy_severity == :failure &&
            "text-red-600",
          @bell_alert? && @deploy_signal? && @unread_count == 0 && @deploy_severity == :warning &&
            "text-amber-500"
        ]}
      />
      <span
        :if={@unread_count > 0}
        id={@id <> "-badge"}
        class="absolute -right-1.5 -top-1.5 inline-flex min-w-4 items-center justify-center rounded-full bg-red-600 px-1 text-[10px] font-semibold leading-4 text-white"
      >
        {@unread_count}
      </span>
      <span
        :if={@deploy_signal? and @unread_count == 0}
        id={@id <> "-dot"}
        class={[
          "absolute -right-0.5 -top-0.5 size-2 rounded-full",
          deploy_dot_class(@deploy_severity)
        ]}
        aria-hidden="true"
      ></span>
    </button>
    """
  end

  attr :open, :boolean, required: true
  attr :loaded?, :boolean, required: true
  attr :notifications, :list, required: true
  attr :unread_count, :integer, required: true
  attr :user_id, :string, required: true
  attr :error, :string, default: nil
  attr :info, :string, default: nil
  attr :preferences, :any, required: true
  attr :preferences_form, :any, required: true
  attr :admin?, :boolean, required: true
  attr :device_stats, :any, default: nil
  attr :devices, :list, default: []
  attr :deploy_failure, :any, default: nil
  attr :deploy_in_progress, :any, default: nil
  attr :update_available, :boolean, default: false
  attr :deploy_drift, :any, default: nil
  attr :update_commits_behind, :integer, default: 0
  attr :codex_approvals, :list, default: []
  attr :grok_permission_requests, :list, default: []

  def notifications_drawer(assigns) do
    assigns =
      assigns
      |> assign(:event_types, @event_types)
      |> assign(:channels, @channels)
      |> assign(:deploy_system_visible?, deploy_system_visible?(assigns))
      |> assign(:drift_visible?, drift_visible?(assigns))
      |> assign(
        :pending_agent_approval_count,
        pending_codex_approval_count(assigns.codex_approvals) +
          length(assigns.grok_permission_requests)
      )

    ~H"""
    <div :if={@open} id="notifications-drawer" class="fixed inset-0 z-40 pointer-events-none">
      <div class="absolute inset-0 bg-black/20 pointer-events-auto" phx-click="notifications:close">
      </div>
      <aside
        class="absolute right-0 top-0 bottom-0 flex w-[420px] max-w-[92vw] flex-col border-l bg-white pointer-events-auto shadow-xl"
        role="complementary"
        aria-label="Notifications drawer"
      >
        <header class="flex items-center justify-between border-b px-4 py-3">
          <div>
            <h2 class="text-sm font-semibold tracking-tight text-zinc-950">Notifications</h2>
            <p id="notifications-drawer-count" class="font-mono text-[11px] text-zinc-500">
              {@unread_count} unread for {@user_id}
              <span :if={@pending_agent_approval_count > 0}>
                · {@pending_agent_approval_count} agent approval{if @pending_agent_approval_count ==
                                                                      1,
                                                                    do: "",
                                                                    else: "s"}
              </span>
            </p>
          </div>
          <div class="flex items-center gap-1">
            <button
              id="notifications-mark-all-read"
              phx-click="notifications:mark_all_read"
              class="rounded border px-2 py-0.5 text-[11px] text-zinc-700 hover:bg-zinc-50"
              title="Mark all read"
            >
              all read
            </button>
            <button
              phx-click="notifications:refresh"
              class="rounded border px-2 py-0.5 text-[11px] hover:bg-zinc-50"
              title="Refresh notifications"
            >
              ↻
            </button>
            <button
              id="notifications-drawer-close"
              phx-click="notifications:close"
              class="rounded border px-2 py-0.5 text-[11px] hover:bg-zinc-50"
              title="Close"
            >
              ×
            </button>
          </div>
        </header>

        <div
          :if={@error}
          id="notifications-error"
          class="border-b border-red-200 bg-red-50 px-4 py-2 text-xs text-red-700"
        >
          {@error}
        </div>
        <div
          :if={@info}
          id="notifications-info"
          class="border-b border-emerald-200 bg-emerald-50 px-4 py-2 text-xs text-emerald-700"
        >
          {@info}
        </div>

        <div class="min-h-0 flex-1 space-y-4 overflow-auto px-3 py-3">
          <AgentApprovals.agent_approvals
            codex_approvals={@codex_approvals}
            grok_requests={@grok_permission_requests}
          />

          <section :if={@deploy_system_visible?} id="deploy-system-section" class="space-y-2">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">System</h3>

            <article
              :if={@deploy_failure}
              id="deploy-system-failure"
              class="rounded border border-red-200 bg-red-50 p-3 text-red-950 shadow-sm"
            >
              <div class="text-sm font-semibold">Deploy failed</div>
              <p class="mt-1 text-xs text-red-900/85">
                {deploy_field(@deploy_failure, :message, "The on-box deploy poller aborted.")}
              </p>
              <p class="mt-2 font-mono text-[10px] text-red-900/70">
                target: {deploy_field(@deploy_failure, :target_short) ||
                  deploy_field(@deploy_failure, :target_sha, "unknown")}
              </p>
            </article>

            <article
              :if={@deploy_in_progress && !@deploy_failure}
              id="deploy-system-in-progress"
              class="flex items-center gap-2 rounded border border-sky-200 bg-sky-50 p-3 text-sm text-sky-950 shadow-sm"
            >
              <span class="size-2 shrink-0 animate-pulse rounded-full bg-sky-500"></span>
              <span>
                {deploy_field(@deploy_in_progress, :message, "Deploy in progress…")}
              </span>
            </article>

            <article
              :if={@update_available && !@deploy_failure && !@deploy_in_progress}
              id="deploy-system-update"
              class="flex flex-wrap items-center gap-2 rounded border border-indigo-200 bg-indigo-50 p-3 text-sm text-indigo-950 shadow-sm"
            >
              <span class="size-2 shrink-0 rounded-full bg-indigo-500"></span>
              <span class="font-medium">New version available</span>
              <span
                :if={@update_commits_behind > 0}
                class="rounded-full bg-indigo-200 px-1.5 py-0.5 text-[10px] font-semibold tabular-nums text-indigo-900"
              >
                {@update_commits_behind}
              </span>
              <button
                id="deploy-update-now"
                type="button"
                phx-hook="DeployUpdateNow"
                class="ml-auto rounded bg-indigo-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-indigo-500"
              >
                Update now
              </button>
            </article>

            <article
              :if={@drift_visible?}
              id="deploy-system-drift"
              class="rounded border border-amber-200 bg-amber-50 p-3 text-amber-950 shadow-sm"
            >
              <div class="text-sm font-semibold">Running revision is not durable</div>
              <p class="mt-1 text-xs text-amber-900/85">
                {deploy_field(@deploy_drift, :message, "Running revision differs from origin/master.")}
              </p>
              <p class="mt-2 font-mono text-[10px] text-amber-900/70">
                current: {deploy_field(@deploy_drift, :current, "unknown")}
              </p>
              <button
                id="deploy-sync-now"
                type="button"
                phx-hook="DeploySyncNow"
                class="mt-2 rounded bg-amber-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-amber-500"
              >
                Sync now
              </button>
            </article>
          </section>

          <%= if not @loaded? do %>
            <div
              id="notifications-loading"
              class="rounded border border-zinc-200 bg-zinc-50 px-4 py-6 text-sm text-zinc-500"
            >
              Loading notifications…
            </div>
          <% else %>
            <div
              :if={@notifications == []}
              id="notifications-empty"
              class="rounded border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
            >
              No open notifications.
            </div>

            <div class="space-y-2">
              <article
                :for={notification <- @notifications}
                id={"notification-#{notification.id}"}
                class={[
                  "rounded border p-3 shadow-sm transition hover:shadow",
                  severity_class(notification.severity),
                  if(is_nil(notification.read_at), do: "border-l-4", else: "opacity-80")
                ]}
              >
                <div class="min-w-0 space-y-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="text-sm font-semibold">{notification.title}</h3>
                    <span class="rounded bg-black/5 px-2 py-0.5 text-[11px] font-medium uppercase tracking-wide">
                      {notification.type}
                    </span>
                    <span
                      :if={notification.occurrence_count > 1}
                      class="rounded bg-black/5 px-2 py-0.5 text-[11px] font-medium"
                    >
                      {notification.occurrence_count} grouped
                    </span>
                  </div>
                  <p :if={notification.body} class="text-sm text-current/75">{notification.body}</p>
                  <p class="text-xs text-current/55">
                    {status_label(notification)} · {time_label(notification.inserted_at)}
                  </p>
                </div>

                <div class="mt-2 flex flex-wrap gap-2">
                  <button
                    type="button"
                    id={"notification-read-#{notification.id}"}
                    phx-click="notifications:mark_read"
                    phx-value-id={notification.id}
                    class="inline-flex items-center gap-1 rounded border border-current/20 px-2 py-1 text-xs font-medium transition hover:bg-black/5"
                  >
                    <.icon name="hero-envelope-open" class="size-3.5" /> Read
                  </button>
                  <button
                    type="button"
                    id={"notification-resolve-#{notification.id}"}
                    phx-click="notifications:resolve"
                    phx-value-id={notification.id}
                    class="inline-flex items-center gap-1 rounded border border-current/20 px-2 py-1 text-xs font-medium transition hover:bg-black/5"
                  >
                    <.icon name="hero-check" class="size-3.5" /> Resolve
                  </button>
                  <button
                    type="button"
                    id={"notification-mute-#{notification.id}"}
                    phx-click="notifications:mute"
                    phx-value-id={notification.id}
                    class="inline-flex items-center gap-1 rounded border border-current/20 px-2 py-1 text-xs font-medium transition hover:bg-black/5"
                  >
                    <.icon name="hero-bell-slash" class="size-3.5" /> Mute
                  </button>
                </div>
              </article>
            </div>

            <details
              :if={@preferences}
              id="notification-preferences"
              class="rounded border border-zinc-200 bg-white"
            >
              <summary class="cursor-pointer select-none px-3 py-2 text-xs font-semibold uppercase tracking-wide text-zinc-500 hover:bg-zinc-50">
                Delivery preferences
              </summary>
              <.form
                id="notification-preferences-form"
                for={@preferences_form}
                phx-submit="notifications:save_preferences"
                class="space-y-4 border-t border-zinc-200 p-3"
              >
                <div class="overflow-x-auto">
                  <table class="min-w-full text-sm">
                    <thead>
                      <tr class="border-b border-zinc-200 text-left text-xs uppercase tracking-wide text-zinc-500">
                        <th class="py-2 pr-4 font-medium">Event</th>
                        <th :for={{label, _channel} <- @channels} class="px-2 py-2 font-medium">
                          {label}
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={{label, type} <- @event_types}
                        class="border-b border-zinc-100 last:border-0"
                      >
                        <td class="py-2 pr-4 font-medium text-zinc-800">{label}</td>
                        <td :for={{_label, channel} <- @channels} class="px-2 py-2">
                          <.input
                            id={"pref-#{type}-#{channel}"}
                            type="checkbox"
                            name={"preferences[types][#{type}][channels][#{channel}]"}
                            checked={preference_enabled?(@preferences, type, channel)}
                            label=""
                            class="size-4 rounded border-zinc-300 text-zinc-900"
                          />
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <div class="grid gap-3 border-t border-zinc-200 pt-3 sm:grid-cols-3">
                  <.input
                    id="quiet-hours-enabled"
                    type="checkbox"
                    name="preferences[quiet_hours][enabled]"
                    checked={quiet_enabled?(@preferences)}
                    label="Quiet hours"
                    class="size-4 rounded border-zinc-300 text-zinc-900"
                  />
                  <.input
                    id="quiet-hours-start"
                    type="time"
                    name="preferences[quiet_hours][start]"
                    label="Start"
                    value={quiet_value(@preferences, "start", "22:00")}
                    class="w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                  <.input
                    id="quiet-hours-end"
                    type="time"
                    name="preferences[quiet_hours][end]"
                    label="End"
                    value={quiet_value(@preferences, "end", "08:00")}
                    class="w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-950"
                  />
                </div>

                <button
                  id="notification-preferences-submit"
                  type="submit"
                  class="inline-flex items-center gap-2 rounded bg-zinc-950 px-3 py-1.5 text-sm font-medium text-white transition hover:bg-zinc-800"
                >
                  <.icon name="hero-check" class="size-4" /> Save Preferences
                </button>
              </.form>
            </details>

            <details
              :if={@admin? and @device_stats}
              id="push-device-admin"
              class="rounded border border-zinc-200 bg-white"
            >
              <summary class="cursor-pointer select-none px-3 py-2 text-xs font-semibold uppercase tracking-wide text-zinc-500 hover:bg-zinc-50">
                Push devices — {@device_stats.active} active · {@device_stats.disabled} disabled
              </summary>
              <div class="overflow-x-auto border-t border-zinc-200 p-3">
                <table class="min-w-full text-left text-sm">
                  <thead>
                    <tr class="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500">
                      <th class="py-2 pr-4 font-medium">Platform</th>
                      <th class="px-2 py-2 font-medium">Scope</th>
                      <th class="px-2 py-2 font-medium">User</th>
                      <th class="px-2 py-2 font-medium">Status</th>
                      <th class="px-2 py-2 font-medium">Failures</th>
                      <th class="px-2 py-2 font-medium">Seen</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={device <- @devices} class="border-b border-zinc-100 last:border-0">
                      <td class="py-2 pr-4 font-medium text-zinc-800">{device.platform}</td>
                      <td class="px-2 py-2 text-zinc-600">{device.scope}:{device.scope_id}</td>
                      <td class="px-2 py-2 text-zinc-600">{device.user_id || "none"}</td>
                      <td class="px-2 py-2 text-zinc-600">{device.provider_status}</td>
                      <td class="px-2 py-2 text-zinc-600">{device.failure_count}</td>
                      <td class="px-2 py-2 text-zinc-600">{time_label(device.last_seen_at)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </details>
          <% end %>
        </div>
      </aside>
    </div>
    """
  end

  defp pending_codex_approval_count(approvals) do
    Enum.count(approvals, fn approval ->
      Map.get(approval, :status, Map.get(approval, "status")) == "pending"
    end)
  end

  defp deploy_severity(assigns) do
    cond do
      assigns[:deploy_failure] ->
        :failure

      assigns[:deploy_in_progress] || assigns[:update_available] || drift_visible?(assigns) ->
        :warning

      true ->
        nil
    end
  end

  defp deploy_signal?(assigns), do: deploy_severity(assigns) != nil

  defp deploy_system_visible?(assigns) do
    assigns[:deploy_failure] ||
      assigns[:deploy_in_progress] ||
      (assigns[:update_available] && !assigns[:deploy_failure] && !assigns[:deploy_in_progress]) ||
      drift_visible?(assigns)
  end

  defp drift_visible?(assigns) do
    case assigns[:deploy_drift] do
      nil ->
        false

      drift ->
        reason = drift[:reason] || drift["reason"]

        reason == :manual_revision or
          (is_nil(assigns[:deploy_failure]) and is_nil(assigns[:deploy_in_progress]))
    end
  end

  defp deploy_dot_class(:failure), do: "bg-red-600"
  defp deploy_dot_class(:warning), do: "bg-amber-500"
  defp deploy_dot_class(_), do: "bg-zinc-400"

  defp deploy_field(info, key, default \\ nil)

  defp deploy_field(info, key, default) when is_map(info) do
    Map.get(info, key) || Map.get(info, Atom.to_string(key)) || default
  end

  defp deploy_field(_, _key, default), do: default

  defp bell_title(assigns) do
    cond do
      assigns.deploy_failure -> "Notifications — deploy failed"
      assigns.deploy_in_progress -> "Notifications — deploy in progress"
      assigns.update_available -> "Notifications — update available"
      drift_visible?(assigns) -> "Notifications — revision drift"
      true -> "Notifications"
    end
  end

  defp bell_aria_label(assigns) do
    base = "Notifications"

    cond do
      assigns.unread_count > 0 and deploy_signal?(assigns) ->
        base <>
          " (" <>
          Integer.to_string(assigns.unread_count) <>
          " unread, system alert active)"

      assigns.unread_count > 0 ->
        base <> " (" <> Integer.to_string(assigns.unread_count) <> " unread)"

      deploy_signal?(assigns) ->
        base <> " (system alert active)"

      true ->
        base
    end
  end

  defp preference_enabled?(preference, type, channel) do
    preference.settings
    |> get_in(["types", type, "channels", channel])
    |> case do
      false -> false
      "false" -> false
      _ -> true
    end
  end

  defp quiet_value(preference, key, default) do
    case Map.get(preference.quiet_hours || %{}, key) do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  defp quiet_enabled?(preference),
    do: Map.get(preference.quiet_hours || %{}, "enabled") in [true, "true"]

  defp severity_class("critical"), do: "border-red-300 bg-red-50 text-red-950"
  defp severity_class("error"), do: "border-red-200 bg-red-50 text-red-900"
  defp severity_class("warning"), do: "border-amber-200 bg-amber-50 text-amber-950"
  defp severity_class(_), do: "border-zinc-200 bg-white text-zinc-950"

  defp status_label(notification) do
    cond do
      notification.resolved_at -> "Resolved"
      notification.muted_at -> "Muted"
      notification.read_at -> "Read"
      true -> "Unread"
    end
  end

  defp time_label(nil), do: "never"

  defp time_label(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
