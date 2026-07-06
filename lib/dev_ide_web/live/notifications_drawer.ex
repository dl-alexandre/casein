defmodule DevIdeWeb.NotificationsDrawer do
  @moduledoc """
  Global notifications drawer: bell + unread badge entry point rendered in the
  dashboard header and the workspace cockpit header, opening a right-side
  drawer with the durable notification inbox (list, mark read / resolve /
  mute, mark-all-read), delivery preferences, and the admin push-device table.

  Rendering carried over from the removed `/notifications` full-page LiveView,
  restyled to the cockpit's drawer conventions (see `Show.AuditDrawer`). State
  and events live in `DevIdeWeb.NotificationsDrawerEvents`.
  """

  use DevIdeWeb, :html

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

  def notifications_bell(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="notifications:toggle"
      class="relative inline-flex items-center justify-center rounded border border-base-300 p-1 text-sm text-base-content/80 hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:p-0"
      title="Notifications"
      aria-label={"Notifications (" <> Integer.to_string(@unread_count) <> " unread)"}
    >
      <.icon name="hero-bell" class="size-4" />
      <span
        :if={@unread_count > 0}
        id={@id <> "-badge"}
        class="absolute -right-1.5 -top-1.5 inline-flex min-w-4 items-center justify-center rounded-full bg-red-600 px-1 text-[10px] font-semibold leading-4 text-white"
      >
        {@unread_count}
      </span>
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

  def notifications_drawer(assigns) do
    assigns =
      assigns
      |> assign(:event_types, @event_types)
      |> assign(:channels, @channels)

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
