defmodule DevIdeWeb.NotificationsDrawerEvents do
  # Notifications drawer state + handle_event clauses, delegated from
  # WorkspaceLive.Show (mirrors HistoryEvents). Absorbs the former
  # NotificationLive.Index full-page LiveView into an in-viewer drawer.
  #
  # Lazy by construction: mount only subscribes to the viewer's notification
  # topic and loads the unread *count* (one indexed aggregate — cheap enough
  # for the badge on the connected mount); the inbox list, delivery
  # preferences, and admin push-device stats load the first time the drawer
  # opens, never during mount.
  #
  # User scoping: every read/lifecycle call is keyed by the mounted
  # `socket.assigns.current_user` — notification ids arriving from the client
  # are only honored when the row belongs to that user (mark_read / resolve /
  # mute look the row up by {id, user_id} inside DevIDE.Notifications).
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1]

  alias DevIDE.Notifications
  alias DevIDE.Push
  alias DevIdeWeb.Plugs.ForwardAuth

  @list_opts [limit: 80, open_only: true]

  # --- state -----------------------------------------------------------------

  @doc """
  Drawer defaults + user-topic subscription, piped from both LiveView mounts.

  The static render assigns a zero badge and no inbox; the connected mount
  subscribes and loads the unread count so the badge is correct on first
  connected paint. The list itself stays lazy (see `open/1`).
  """
  def mount(socket) do
    user = socket.assigns[:current_user]
    user_id = current_user_id(user)

    if connected?(socket), do: Notifications.subscribe(user_id)

    socket
    |> assign(:notif_user_id, user_id)
    |> assign(:notif_admin?, ForwardAuth.admin?(user))
    |> assign(:notif_drawer_open, false)
    |> assign(:notif_loaded?, false)
    |> assign(:notif_error, nil)
    |> assign(:notif_info, nil)
    |> assign(:notifications, [])
    |> assign(:notif_preferences, nil)
    |> assign(:notif_preferences_form, to_form(%{}, as: :preferences))
    |> assign(:notif_device_stats, nil)
    |> assign(:notif_devices, [])
    |> assign(
      :notif_unread_count,
      if(connected?(socket), do: Notifications.unread_count(user_id), else: 0)
    )
  end

  @doc """
  `?drawer=notifications` deep link (docs/deep_links.md): open the drawer from
  the URL on either surface. One-shot like `?tab=` — later patches without the
  param leave the drawer alone. The static render only flips the open flag so
  the first paint shows the drawer shell; hydration runs on the connected mount.
  """
  def apply_drawer_param(socket, %{"drawer" => "notifications"}) do
    if socket.assigns[:notif_drawer_open], do: socket, else: open(socket)
  end

  def apply_drawer_param(socket, _params), do: socket

  @doc "Open the drawer and run the first (connected-only) inbox load."
  def open(socket) do
    socket = assign(socket, :notif_drawer_open, true)
    if connected?(socket), do: load_state(socket), else: socket
  end

  @doc """
  Live refresh from `DevIDE.Notifications` user-topic broadcasts
  (`:notification_created` / `:notification_updated`): the badge always
  updates; the inbox list refreshes only while the drawer is open.
  """
  def handle_notification_change(socket) do
    if socket.assigns[:notif_drawer_open] and socket.assigns[:notif_loaded?] do
      load_state(socket)
    else
      assign(
        socket,
        :notif_unread_count,
        Notifications.unread_count(socket.assigns.notif_user_id)
      )
    end
  end

  # --- handle_event ----------------------------------------------------------

  def handle_event("notifications:toggle", _params, socket) do
    socket =
      if socket.assigns.notif_drawer_open,
        do: assign(socket, :notif_drawer_open, false),
        else: open(socket)

    {:noreply, socket}
  end

  def handle_event("notifications:close", _params, socket) do
    {:noreply, assign(socket, :notif_drawer_open, false)}
  end

  def handle_event("notifications:refresh", _params, socket) do
    {:noreply, load_state(socket)}
  end

  def handle_event("notifications:mark_read", %{"id" => id}, socket) do
    _ = Notifications.mark_read(id, socket.assigns.notif_user_id)
    {:noreply, socket |> clear_status() |> load_state()}
  end

  def handle_event("notifications:resolve", %{"id" => id}, socket) do
    _ = Notifications.resolve(id, socket.assigns.notif_user_id)
    {:noreply, socket |> clear_status() |> load_state()}
  end

  def handle_event("notifications:mute", %{"id" => id}, socket) do
    _ = Notifications.mute(id, socket.assigns.notif_user_id)
    {:noreply, socket |> clear_status() |> load_state()}
  end

  def handle_event("notifications:mark_all_read", _params, socket) do
    _ = Notifications.mark_all_read(socket.assigns.notif_user_id)
    {:noreply, socket |> clear_status() |> load_state()}
  end

  def handle_event("notifications:save_preferences", %{"preferences" => params}, socket) do
    attrs = %{
      settings: %{"types" => normalize_types(params["types"] || %{})},
      quiet_hours: normalize_quiet_hours(params["quiet_hours"] || %{})
    }

    case Notifications.put_preferences(socket.assigns.notif_user_id, attrs) do
      {:ok, _preference} ->
        {:noreply,
         socket
         |> assign(:notif_error, nil)
         |> assign(:notif_info, "Notification preferences saved.")
         |> load_state()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:notif_info, nil)
         |> assign(:notif_error, "Notification preferences could not be saved.")}
    end
  end

  def handle_event("notifications:" <> _event, _params, socket), do: {:noreply, socket}

  # --- internals ---------------------------------------------------------------

  defp load_state(socket) do
    user_id = socket.assigns.notif_user_id
    admin? = socket.assigns.notif_admin?

    socket
    |> assign(:notifications, Notifications.list_for_user(user_id, @list_opts))
    |> assign(:notif_unread_count, Notifications.unread_count(user_id))
    |> assign(:notif_preferences, Notifications.get_preferences(user_id))
    |> assign(:notif_device_stats, if(admin?, do: Push.stats()))
    |> assign(:notif_devices, if(admin?, do: Push.list_devices(limit: 12), else: []))
    |> assign(:notif_loaded?, true)
  end

  defp clear_status(socket) do
    socket |> assign(:notif_error, nil) |> assign(:notif_info, nil)
  end

  # Same identity fallback the removed page used: dev/LAN deployments without
  # forward auth act as the single "dev" user.
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
end
