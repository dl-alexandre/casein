defmodule DevIdeWeb.NotificationLive.Index do
  @moduledoc "Durable notification inbox and routing preferences."

  use DevIdeWeb, :live_view

  alias DevIDE.Notifications
  alias DevIDE.Push
  alias DevIdeWeb.Plugs.ForwardAuth

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

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    user_id = current_user_id(user)

    if connected?(socket), do: Notifications.subscribe(user_id)

    socket =
      socket
      |> assign(:page_title, "Notifications")
      |> assign(:user_id, user_id)
      |> assign(:is_admin, ForwardAuth.admin?(user))
      |> assign(:event_types, @event_types)
      |> assign(:channels, @channels)
      |> assign(:preferences_form, to_form(%{}, as: :preferences))
      |> load_state()

    {:ok, socket}
  end

  @impl true
  def handle_info({:notification_created, _notification}, socket),
    do: {:noreply, load_state(socket)}

  def handle_info({:notification_updated, _notification}, socket),
    do: {:noreply, load_state(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    _ = Notifications.mark_read(id, socket.assigns.user_id)
    {:noreply, load_state(socket)}
  end

  def handle_event("resolve", %{"id" => id}, socket) do
    _ = Notifications.resolve(id, socket.assigns.user_id)
    {:noreply, load_state(socket)}
  end

  def handle_event("mute", %{"id" => id}, socket) do
    _ = Notifications.mute(id, socket.assigns.user_id)
    {:noreply, load_state(socket)}
  end

  def handle_event("save_preferences", %{"preferences" => params}, socket) do
    attrs = %{
      settings: %{"types" => normalize_types(params["types"] || %{})},
      quiet_hours: normalize_quiet_hours(params["quiet_hours"] || %{})
    }

    case Notifications.put_preferences(socket.assigns.user_id, attrs) do
      {:ok, _preference} ->
        {:noreply,
         socket
         |> put_flash(:info, "Notification preferences saved.")
         |> load_state()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Notification preferences could not be saved.")}
    end
  end

  defp load_state(socket) do
    user_id = socket.assigns.user_id
    preferences = Notifications.get_preferences(user_id)

    socket
    |> assign(:notifications, Notifications.list_for_user(user_id, limit: 80, open_only: true))
    |> assign(:unread_count, Notifications.unread_count(user_id))
    |> assign(:preferences, preferences)
    |> assign(:device_stats, maybe_device_stats(socket.assigns.is_admin))
    |> assign(:devices, maybe_devices(socket.assigns.is_admin))
  end

  defp maybe_device_stats(true), do: Push.stats()
  defp maybe_device_stats(_), do: nil

  defp maybe_devices(true), do: Push.list_devices(limit: 12)
  defp maybe_devices(_), do: []

  defp current_user_id(%{id: id}) when is_binary(id), do: id
  defp current_user_id(%{"id" => id}) when is_binary(id), do: id
  defp current_user_id(_user), do: "dev"

  defp normalize_types(types) do
    types
    |> Enum.map(fn {type, attrs} ->
      channels =
        attrs
        |> Map.get("channels", %{})
        |> Enum.map(fn {channel, enabled} -> {channel, enabled in [true, "true"]} end)
        |> Map.new()

      {type, %{"channels" => channels}}
    end)
    |> Map.new()
  end

  defp normalize_quiet_hours(params) do
    %{
      "enabled" => Map.get(params, "enabled") in [true, "true"],
      "start" => blank_to_default(Map.get(params, "start"), "22:00"),
      "end" => blank_to_default(Map.get(params, "end"), "08:00")
    }
  end

  defp blank_to_default(value, default) when value in [nil, ""], do: default
  defp blank_to_default(value, _default), do: value

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="notification-center" class="space-y-6">
        <header class="flex flex-col gap-3 border-b border-zinc-200 pb-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight text-zinc-950">Notifications</h1>
            <p class="text-sm text-zinc-500">
              {@unread_count} unread for {@user_id}
            </p>
          </div>
          <.link
            navigate={~p"/"}
            class="inline-flex items-center gap-2 self-start rounded border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400 hover:bg-zinc-50"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Workspaces
          </.link>
        </header>

        <section class="space-y-3">
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">Inbox</h2>
            <span class="text-xs text-zinc-500">{length(@notifications)} open</span>
          </div>

          <div
            :if={@notifications == []}
            id="notifications-empty"
            class="rounded border border-zinc-200 bg-white p-6 text-sm text-zinc-500"
          >
            No open notifications.
          </div>

          <div class="space-y-2">
            <article
              :for={notification <- @notifications}
              id={"notification-#{notification.id}"}
              class={[
                "rounded border p-4 shadow-sm transition hover:shadow",
                severity_class(notification.severity)
              ]}
            >
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
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

                <div class="flex shrink-0 flex-wrap gap-2">
                  <button
                    type="button"
                    id={"notification-read-#{notification.id}"}
                    phx-click="mark_read"
                    phx-value-id={notification.id}
                    class="inline-flex items-center gap-1 rounded border border-current/20 px-2.5 py-1.5 text-xs font-medium transition hover:bg-black/5"
                  >
                    <.icon name="hero-envelope-open" class="size-3.5" /> Read
                  </button>
                  <button
                    type="button"
                    id={"notification-resolve-#{notification.id}"}
                    phx-click="resolve"
                    phx-value-id={notification.id}
                    class="inline-flex items-center gap-1 rounded border border-current/20 px-2.5 py-1.5 text-xs font-medium transition hover:bg-black/5"
                  >
                    <.icon name="hero-check" class="size-3.5" /> Resolve
                  </button>
                  <button
                    type="button"
                    id={"notification-mute-#{notification.id}"}
                    phx-click="mute"
                    phx-value-id={notification.id}
                    class="inline-flex items-center gap-1 rounded border border-current/20 px-2.5 py-1.5 text-xs font-medium transition hover:bg-black/5"
                  >
                    <.icon name="hero-bell-slash" class="size-3.5" /> Mute
                  </button>
                </div>
              </div>
            </article>
          </div>
        </section>

        <section class="rounded border border-zinc-200 bg-white p-4 shadow-sm">
          <h2 class="mb-4 text-sm font-semibold uppercase tracking-wide text-zinc-500">
            Delivery Preferences
          </h2>
          <.form
            id="notification-preferences-form"
            for={@preferences_form}
            phx-submit="save_preferences"
            class="space-y-5"
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

            <div class="grid gap-3 border-t border-zinc-200 pt-4 sm:grid-cols-3">
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
              class="inline-flex items-center gap-2 rounded bg-zinc-950 px-3 py-2 text-sm font-medium text-white transition hover:bg-zinc-800"
            >
              <.icon name="hero-check" class="size-4" /> Save Preferences
            </button>
          </.form>
        </section>

        <section
          :if={@is_admin}
          id="push-device-admin"
          class="rounded border border-zinc-200 bg-white p-4 shadow-sm"
        >
          <div class="mb-4 flex flex-col gap-1">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500">Push Devices</h2>
            <p class="text-sm text-zinc-500">
              {@device_stats.active} active · {@device_stats.disabled} disabled
            </p>
          </div>
          <div class="overflow-x-auto">
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
        </section>
      </div>
    </Layouts.app>
    """
  end
end
