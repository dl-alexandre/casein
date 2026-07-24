defmodule DevideMob.SessionClient do
  @moduledoc """
  Phoenix Channel client for the mobile session companion.

  Runs on the device, holds a single WSS connection to the dev_ide host's
  `/socket` (`CaseinWeb.UserSocket`), joins one `session:<workspace_id>` topic
  per watched workspace (`CaseinWeb.SessionChannel`), and can also join the
  authenticated user's `mobile:user:me` card stream.

  Screens are pure consumers — they call `watch/2` on mount and receive, on the
  pid they pass:

      {:session_snapshot, workspace_id, payload}   # join reply + every update
      {:session_status,   workspace_id, status}
        # :joined | :connecting | :disconnected | :error
        # or {:error | :disconnected, reason} for differentiated recovery copy

  which they handle in `handle_info/2` exactly like `TerminalScreen` handles
  `{:vt_bytes, _}`. This is the network analogue of the host-distribution
  transport the terminal screen uses — same "push into the screen" shape, but
  it works from the field over WSS instead of requiring the same LAN.

  Connection credentials (`url`, `token`) are provisioned out-of-band — the
  device cannot mint its own token (it has no `secret_key_base`). The intended
  flow is QR/paste pairing: the web cockpit renders a code with a stable origin
  descriptor plus `{url, token, workspace_id}`. The device consumes it and
  calls `configure/1`. `DevideMob.SessionConfig` persists the
  last pairing so the client auto-connects on boot.
  """

  use Slipstream
  require Logger

  alias DevideMob.SessionConfig
  alias Slipstream.Socket

  @name __MODULE__
  @mobile_cards_topic "mobile:user:me"

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    Slipstream.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Provision/refresh connection credentials (from QR pairing) and connect."
  @spec configure(map()) :: :ok
  def configure(%{url: url, token: token} = pairing)
      when is_binary(url) and is_binary(token) do
    SessionConfig.put_pairing(pairing)
    cast({:configure, url, token})
  end

  @doc false
  @spec configure(String.t(), String.t()) :: :ok
  def configure(url, token) when is_binary(url) and is_binary(token) do
    SessionConfig.put_pairing(url, token)
    cast({:configure, url, token})
  end

  @doc "Switch the single live connection to a trusted saved origin."
  @spec activate_origin(String.t()) :: :ok | :error
  def activate_origin(origin_id) when is_binary(origin_id) do
    case SessionConfig.activate_origin(origin_id) do
      {:ok, %{url: active_url, token: token}} ->
        cast({:activate_origin, active_url, token})

      :error ->
        :error
    end
  end

  @doc "Switch the single live connection to a saved host profile."
  @spec activate_host(String.t()) :: :ok | :error
  def activate_host(url) when is_binary(url) do
    case SessionConfig.activate_host(url) do
      {:ok, active_url, token} ->
        cast({:configure, active_url, token})

      :error ->
        :error
    end
  end

  @doc "Forget pairing credentials and disconnect the session channel client."
  @spec clear_pairing() :: :ok
  def clear_pairing do
    SessionConfig.clear_pairing()
    cast(:clear_pairing)
  end

  @doc "Begin watching a workspace; `subscriber` receives snapshot/status messages."
  @spec watch(String.t(), pid()) :: :ok
  def watch(workspace_id, subscriber \\ self())
      when is_binary(workspace_id) and is_pid(subscriber) do
    cast({:watch, workspace_id, subscriber})
  end

  @doc "Stop watching a workspace from `subscriber`."
  @spec unwatch(String.t(), pid()) :: :ok
  def unwatch(workspace_id, subscriber \\ self())
      when is_binary(workspace_id) and is_pid(subscriber) do
    cast({:unwatch, workspace_id, subscriber})
  end

  @doc "Begin watching the authenticated user's mobile card stream."
  @spec watch_mobile_cards(pid()) :: :ok
  def watch_mobile_cards(subscriber \\ self()) when is_pid(subscriber) do
    cast({:watch_mobile_cards, subscriber})
  end

  @doc "Stop watching the authenticated user's mobile card stream."
  @spec unwatch_mobile_cards(pid()) :: :ok
  def unwatch_mobile_cards(subscriber \\ self()) when is_pid(subscriber) do
    cast({:unwatch_mobile_cards, subscriber})
  end

  @doc "Send a narrow mobile card action to the authenticated user's card stream."
  @spec card_action(String.t(), String.t(), map() | nil) :: :ok
  def card_action(card_id, action, payload \\ nil)
      when is_binary(card_id) and is_binary(action) and (is_map(payload) or is_nil(payload)) do
    card_action(card_id, action, payload, nil)
  end

  @doc "Send a card action qualified by the card's server-issued origin id."
  @spec card_action(String.t(), String.t(), map() | nil, String.t() | nil) :: :ok
  def card_action(card_id, action, payload, origin_id)
      when is_binary(card_id) and is_binary(action) and
             (is_map(payload) or is_nil(payload)) and
             (is_binary(origin_id) or is_nil(origin_id)) do
    cast({:card_action, card_id, action, payload, origin_id})
  end

  @doc "Report one allowlisted, privacy-bounded resume lifecycle observation."
  @spec mobile_observation(map()) :: :ok
  def mobile_observation(params) when is_map(params) do
    cast({:mobile_observation, params})
  end

  @doc """
  Register this device's OS push token for a workspace. Prefer the user-level
  mobile card stream when joined, with the workspace session channel retained as
  a fallback for older flows. The server stores it and pushes alerts even when
  the app is backgrounded — see `Casein.Push`. The dashboard obtains `token`
  from `mob_notify` after notification permission is granted.
  """
  @spec register_push(String.t(), String.t(), String.t()) :: :ok
  def register_push(workspace_id, token, platform)
      when is_binary(workspace_id) and is_binary(token) and is_binary(platform) do
    cast({:register_push, workspace_id, token, platform})
  end

  @doc """
  Register this device's OS push token for the authenticated user-level mobile
  card stream.

  This is the primary path for `mobile:user:me` cards because it lets the
  backend push needs-review cards before the device has seen or pinned a
  specific workspace.
  """
  @spec register_user_push(String.t(), String.t()) :: :ok
  def register_user_push(token, platform) when is_binary(token) and is_binary(platform) do
    cast({:register_user_push, token, platform})
  end

  # ── Slipstream lifecycle ────────────────────────────────────────────────────

  @impl Slipstream
  def init(_opts) do
    # Start disconnected. Creds arrive via configure/2, or from a persisted
    # pairing on boot. `subscribers` is topic => MapSet of pids.
    socket =
      Socket.new()
      |> assign(:subscribers, %{})
      |> assign(:url, nil)
      |> assign(:token, nil)
      |> assign(:connecting?, false)
      |> assign(:push_registration_refs, %{})
      |> assign(:card_action_refs, %{})

    socket =
      case SessionConfig.pairing() do
        {:ok, url, token} -> do_configure(socket, url, token)
        :error -> socket
      end

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    socket = assign(socket, :connecting?, false)

    # (Re)join every topic that still has subscribers.
    socket =
      socket.assigns.subscribers
      |> Map.keys()
      |> Enum.reduce(socket, fn topic, acc -> join(acc, topic) end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join(topic, reply, socket) do
    notify_joined(socket, topic, reply)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message("session:" <> _workspace_id = topic, "snapshot", payload, socket) do
    notify(socket, topic, {:session_snapshot, workspace_id(topic), payload})
    {:ok, socket}
  end

  def handle_message("session:" <> _workspace_id = topic, "alert", payload, socket) do
    notify(socket, topic, {:session_alert, workspace_id(topic), payload})
    {:ok, socket}
  end

  def handle_message(topic, "cards_snapshot", payload, socket) do
    if mobile_cards_topic?(topic), do: notify(socket, topic, {:mobile_cards_snapshot, payload})
    {:ok, socket}
  end

  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    case pop_push_registration(socket, ref) do
      {nil, socket} ->
        handle_card_action_reply(ref, reply, socket)

      {%{scope: :user}, socket} ->
        notify_push_registration(socket, :user, push_registration_status(reply))
        {:ok, socket}

      {%{workspace_id: workspace_id}, socket} ->
        maybe_notify_push_registration(socket, workspace_id, push_registration_status(reply))
        {:ok, socket}
    end
  end

  defp handle_card_action_reply(ref, reply, socket) do
    case pop_card_action(socket, ref) do
      {nil, socket} ->
        {:ok, socket}

      {%{card_id: card_id}, socket} ->
        notify_card_action_result(socket, card_id, card_action_result(reply))
        {:ok, socket}
    end
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    notify_status(socket, topic, error_status(reason))
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    socket = assign(socket, :connecting?, false)
    status = disconnected_status(reason)

    for topic <- Map.keys(socket.assigns.subscribers), do: notify_status(socket, topic, status)
    notify_pending_push_registrations(socket, {:error, status})
    notify_pending_card_actions(socket, {:error, status})

    socket =
      socket
      |> assign(:push_registration_refs, %{})
      |> assign(:card_action_refs, %{})

    # Reconnect with backoff while we still have credentials and watchers.
    if socket.assigns.url && map_size(socket.assigns.subscribers) > 0 do
      case request_reconnect(socket) do
        {:ok, socket} -> {:ok, socket}
        {:error, _reason} -> {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  # ── GenServer-style extra callbacks ─────────────────────────────────────────

  @impl Slipstream
  def handle_cast({:configure, url, token}, socket) do
    {:noreply, do_configure(socket, url, token)}
  end

  def handle_cast({:activate_origin, url, token}, socket) do
    # Explicit origin resume always establishes a fresh authoritative channel,
    # even when the requested origin is already active.
    {:noreply, socket |> assign(:token, nil) |> do_configure(url, token)}
  end

  def handle_cast(:clear_pairing, socket) do
    socket =
      socket.assigns.subscribers
      |> Map.keys()
      |> Enum.reduce(socket, fn topic, acc ->
        notify_status(acc, topic, :disconnected)
        if joined?(acc, topic), do: leave(acc, topic), else: acc
      end)

    socket =
      if connected?(socket) or socket.assigns.connecting? do
        socket
        |> disconnect()
        |> assign(:connecting?, false)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:subscribers, %{})
     |> assign(:url, nil)
     |> assign(:token, nil)
     |> assign(:connecting?, false)
     |> assign(:push_registration_refs, %{})
     |> assign(:card_action_refs, %{})}
  end

  def handle_cast({:watch, workspace_id, subscriber}, socket) do
    {:noreply, watch_topic(socket, topic(workspace_id), subscriber)}
  end

  def handle_cast({:unwatch, workspace_id, subscriber}, socket) do
    {:noreply, drop_subscriber(socket, topic(workspace_id), subscriber)}
  end

  def handle_cast({:watch_mobile_cards, subscriber}, socket) do
    {:noreply, watch_topic(socket, @mobile_cards_topic, subscriber)}
  end

  def handle_cast({:unwatch_mobile_cards, subscriber}, socket) do
    {:noreply, drop_subscriber(socket, @mobile_cards_topic, subscriber)}
  end

  def handle_cast({:card_action, card_id, action, payload, origin_id}, socket) do
    if connected?(socket) and joined?(socket, @mobile_cards_topic) do
      request_id = new_request_id()

      action_payload =
        %{
          card_id: card_id,
          action: action,
          payload: payload,
          request_id: request_id
        }
        |> maybe_put_origin_id(origin_id)

      case push(socket, @mobile_cards_topic, "card_action", action_payload) do
        {:ok, ref} ->
          {:noreply, track_card_action(socket, ref, card_id)}

        {:error, reason} ->
          notify_card_action_result(socket, card_id, {:error, reason})
          {:noreply, socket}
      end
    else
      notify_card_action_result(socket, card_id, {:error, :not_connected})
      {:noreply, socket}
    end
  end

  def handle_cast({:mobile_observation, params}, socket) do
    if connected?(socket) and joined?(socket, @mobile_cards_topic) do
      _ = push(socket, @mobile_cards_topic, "mobile_observation", params)
    end

    {:noreply, socket}
  end

  def handle_cast({:register_push, workspace_id, token, platform}, socket) do
    topic = topic(workspace_id)

    socket =
      socket
      |> maybe_push_registration(@mobile_cards_topic, workspace_id, %{
        workspace_id: workspace_id,
        token: token,
        platform: platform
      })
      |> maybe_push_registration(topic, workspace_id, %{token: token, platform: platform})

    {:noreply, socket}
  end

  def handle_cast({:register_user_push, token, platform}, socket) do
    socket =
      maybe_user_push_registration(socket, %{
        token: token,
        platform: platform
      })

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    # A screen went away — drop it from every topic, leave topics that empty out.
    socket =
      socket.assigns.subscribers
      |> Map.keys()
      |> Enum.reduce(socket, fn topic, acc -> drop_subscriber(acc, topic, pid) end)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Internals ───────────────────────────────────────────────────────────────

  defp cast(message) do
    if Process.whereis(@name), do: GenServer.cast(@name, message)
    :ok
  end

  defp maybe_put_origin_id(payload, origin_id)
       when is_binary(origin_id) and origin_id != "",
       do: Map.put(payload, :origin_id, origin_id)

  defp maybe_put_origin_id(payload, _origin_id), do: payload

  defp watch_topic(socket, topic, subscriber) do
    Process.monitor(subscriber)

    subscribers =
      Map.update(
        socket.assigns.subscribers,
        topic,
        MapSet.new([subscriber]),
        &MapSet.put(&1, subscriber)
      )

    socket = assign(socket, :subscribers, subscribers)

    cond do
      not connected?(socket) -> ensure_connection_requested(socket)
      joined?(socket, topic) -> socket
      true -> join(socket, topic)
    end
  end

  defp do_configure(socket, url, token) do
    changed? = socket.assigns.url != url or socket.assigns.token != token
    origin_changed? = different_origin?(socket.assigns.url, url)

    socket =
      if changed? and (connected?(socket) or socket.assigns.connecting?) do
        socket
        |> disconnect()
        |> assign(:connecting?, false)
      else
        socket
      end

    socket = if origin_changed?, do: clear_origin_state(socket), else: socket
    _ = resolve_host(url)
    socket = socket |> assign(:url, url) |> assign(:token, token)

    if changed?, do: request_connect(socket), else: ensure_connection_requested(socket)
  end

  # Pairing a second host can happen while the previous dashboard is still
  # mounted behind the pairing screen. Drop every origin-owned in-memory
  # reference before the new socket connects so old workspace topics, push
  # acknowledgements, and card actions cannot cross into the new origin.
  defp clear_origin_state(socket) do
    notify_all_status(socket, :disconnected)
    notify_pending_push_registrations(socket, {:error, :host_switched})
    notify_pending_card_actions(socket, {:error, :host_switched})

    socket
    |> assign(:subscribers, %{})
    |> assign(:push_registration_refs, %{})
    |> assign(:card_action_refs, %{})
  end

  defp different_origin?(nil, _url), do: false

  defp different_origin?(current_url, next_url) do
    normalize_origin(current_url) != normalize_origin(next_url)
  end

  defp normalize_origin(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  # iOS needs its native resolver for some public and VPN-provided hostnames.
  # Resolve each configured origin, not only the profile that happened to be
  # active when the app booted.
  defp resolve_host(url) do
    with host when is_binary(host) <- URI.parse(url).host,
         {:error, _reason} <- :inet.parse_address(String.to_charlist(host)) do
      Mob.DNS.resolve(host)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp ensure_connection_requested(socket) do
    cond do
      connected?(socket) or socket.assigns.connecting? ->
        socket

      is_binary(socket.assigns.url) and is_binary(socket.assigns.token) ->
        case request_reconnect(socket) do
          {:ok, socket} ->
            socket

          {:error, :no_config} ->
            request_connect(socket)

          {:error, :connected} ->
            socket
        end

      true ->
        socket
    end
  end

  defp request_connect(socket) do
    case connect(socket, connect_opts(socket)) do
      {:ok, socket} ->
        assign(socket, :connecting?, true)

      {:error, reason} ->
        Logger.warning("SessionClient connect failed: #{inspect(reason)}")
        notify_all_status(socket, {:disconnected, classify_disconnect_reason(reason)})
        socket
    end
  end

  defp request_reconnect(socket) do
    case reconnect(socket) do
      {:ok, socket} -> {:ok, assign(socket, :connecting?, true)}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_push_registration(socket, topic, workspace_id, payload) do
    if connected?(socket) and joined?(socket, topic) do
      case push(socket, topic, "register_push", payload) do
        {:ok, ref} ->
          update_push_registration_refs(socket, ref, %{
            workspace_id: workspace_id,
            topic: topic
          })

        {:error, reason} ->
          notify_push_registration(socket, workspace_id, {:error, reason})
          socket
      end
    else
      socket
    end
  end

  defp maybe_user_push_registration(socket, payload) do
    if connected?(socket) and joined?(socket, @mobile_cards_topic) do
      case push(socket, @mobile_cards_topic, "register_push", payload) do
        {:ok, ref} ->
          update_push_registration_refs(socket, ref, %{
            scope: :user,
            topic: @mobile_cards_topic
          })

        {:error, reason} ->
          notify_push_registration(socket, :user, {:error, reason})
          socket
      end
    else
      socket
    end
  end

  defp update_push_registration_refs(socket, ref, metadata) do
    refs = socket.assigns[:push_registration_refs] || %{}
    assign(socket, :push_registration_refs, Map.put(refs, ref, metadata))
  end

  defp pop_push_registration(socket, ref) do
    refs = socket.assigns[:push_registration_refs] || %{}
    {metadata, refs} = Map.pop(refs, ref)
    {metadata, assign(socket, :push_registration_refs, refs)}
  end

  defp track_card_action(socket, ref, card_id) do
    refs = socket.assigns[:card_action_refs] || %{}
    assign(socket, :card_action_refs, Map.put(refs, ref, %{card_id: card_id}))
  end

  defp pop_card_action(socket, ref) do
    refs = socket.assigns[:card_action_refs] || %{}
    {metadata, refs} = Map.pop(refs, ref)
    {metadata, assign(socket, :card_action_refs, refs)}
  end

  # Deliver an action reply to every subscriber; screens correlate by card_id.
  defp notify_card_action_result(socket, card_id, result) do
    socket.assigns.subscribers
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1))
    |> Enum.each(&send(&1, {:card_action_result, card_id, result}))
  end

  # Reply values arrive from the server (trusted transport); never atom-convert
  # the reason string.
  defp card_action_result({:ok, payload}) when is_map(payload), do: {:ok, payload}
  defp card_action_result(:ok), do: {:ok, %{}}
  defp card_action_result({:error, %{"reason" => reason}}), do: {:error, reason}
  defp card_action_result({:error, %{reason: reason}}), do: {:error, reason}
  defp card_action_result({:error, reason}), do: {:error, reason}
  defp card_action_result(other), do: {:error, other}

  defp new_request_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp push_registration_status(:ok), do: :registered
  defp push_registration_status({:ok, _payload}), do: :registered
  defp push_registration_status({:error, %{"reason" => reason}}), do: {:error, reason}
  defp push_registration_status({:error, %{reason: reason}}), do: {:error, reason}
  defp push_registration_status({:error, reason}), do: {:error, reason}
  defp push_registration_status(other), do: {:error, other}

  defp maybe_notify_push_registration(socket, workspace_id, :registered) do
    unless pending_push_registration?(socket, workspace_id) do
      notify_push_registration(socket, workspace_id, :registered)
    end
  end

  defp maybe_notify_push_registration(socket, workspace_id, {:error, _reason} = status) do
    notify_push_registration(socket, workspace_id, status)
  end

  defp pending_push_registration?(socket, workspace_id) do
    socket.assigns[:push_registration_refs]
    |> Kernel.||(%{})
    |> Map.values()
    |> Enum.any?(&(Map.get(&1, :workspace_id) == workspace_id))
  end

  defp connect_opts(socket) do
    uri = ws_uri(socket.assigns.url, socket.assigns.token)

    [
      uri: uri,
      mint_opts: mint_opts(uri)
    ]
  end

  defp mint_opts(uri) do
    opts = [protocols: [:http1]]

    if URI.parse(uri).scheme == "wss" do
      case bundled_cacertfile() do
        {:ok, path} -> Keyword.put(opts, :transport_opts, cacertfile: path)
        :error -> opts
      end
    else
      opts
    end
  end

  defp bundled_cacertfile do
    [
      mobile_priv_path("castore/cacerts.pem"),
      app_priv_path("castore/cacerts.pem")
    ]
    |> Enum.find(&(&1 && File.regular?(&1)))
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  defp mobile_priv_path(relative_path) do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> nil
      beams_dir -> Path.join([beams_dir, "priv", relative_path])
    end
  end

  defp app_priv_path(relative_path) do
    case :code.priv_dir(:devide_mob) do
      priv_dir when is_list(priv_dir) -> Path.join([List.to_string(priv_dir), relative_path])
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  end

  # Accepts either a base host URL ("https://host") or an explicit socket URL.
  # Normalizes to the Phoenix websocket endpoint with the auth token in query.
  defp ws_uri(url, token) do
    uri = URI.parse(url)
    scheme = if uri.scheme in ["https", "wss"], do: "wss", else: "ws"
    path = if uri.path in [nil, "", "/"], do: "/socket/websocket", else: ensure_ws_path(uri.path)

    %URI{uri | scheme: scheme, path: path, query: URI.encode_query(%{"token" => token})}
    |> URI.to_string()
  end

  defp ensure_ws_path(path) do
    if String.ends_with?(path, "/websocket"),
      do: path,
      else: String.trim_trailing(path, "/") <> "/websocket"
  end

  defp drop_subscriber(socket, topic, subscriber) do
    case Map.get(socket.assigns.subscribers, topic) do
      nil ->
        socket

      pids ->
        remaining = MapSet.delete(pids, subscriber)

        if MapSet.size(remaining) == 0 do
          socket = assign(socket, :subscribers, Map.delete(socket.assigns.subscribers, topic))
          if joined?(socket, topic), do: leave(socket, topic), else: socket
        else
          assign(socket, :subscribers, Map.put(socket.assigns.subscribers, topic, remaining))
        end
    end
  end

  defp notify(socket, topic, message) do
    socket.assigns.subscribers
    |> Map.get(topic, MapSet.new())
    |> Enum.each(&send(&1, message))
  end

  defp notify_all_status(socket, status) do
    for topic <- Map.keys(socket.assigns.subscribers) do
      notify_status(socket, topic, status)
    end
  end

  defp notify_pending_push_registrations(socket, status) do
    (socket.assigns[:push_registration_refs] || %{})
    |> Map.values()
    |> Enum.uniq_by(&push_registration_key/1)
    |> Enum.each(fn metadata ->
      notify_push_registration(socket, push_registration_key(metadata), status)
    end)
  end

  defp push_registration_key(%{scope: :user}), do: :user
  defp push_registration_key(%{workspace_id: workspace_id}), do: workspace_id

  defp notify_pending_card_actions(socket, result) do
    (socket.assigns[:card_action_refs] || %{})
    |> Map.values()
    |> Enum.each(fn %{card_id: card_id} ->
      notify_card_action_result(socket, card_id, result)
    end)
  end

  defp notify_push_registration(socket, workspace_id, status) do
    socket.assigns.subscribers
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1))
    |> Enum.each(&send(&1, {:push_registration_status, workspace_id, status}))
  end

  defp notify_joined(socket, "session:" <> workspace_id = topic, reply) do
    notify(socket, topic, {:session_snapshot, workspace_id, reply})
    notify(socket, topic, {:session_status, workspace_id, :joined})
  end

  defp notify_joined(socket, topic, reply) do
    if mobile_cards_topic?(topic) do
      notify(socket, topic, {:mobile_cards_snapshot, reply})
      notify(socket, topic, {:mobile_cards_status, :joined})
    end
  end

  defp notify_status(socket, "session:" <> workspace_id = topic, status) do
    notify(socket, topic, {:session_status, workspace_id, status})
  end

  defp notify_status(socket, topic, status) do
    if mobile_cards_topic?(topic), do: notify(socket, topic, {:mobile_cards_status, status})
  end

  defp error_status(reason), do: {:error, classify_close_reason(reason)}

  defp disconnected_status(reason) do
    case classify_disconnect_reason(reason) do
      :offline -> :disconnected
      reason -> {:disconnected, reason}
    end
  end

  defp classify_close_reason({:error, payload}),
    do: payload |> reason_value() |> classify_join_reason()

  defp classify_close_reason(payload), do: payload |> reason_value() |> classify_join_reason()

  defp classify_join_reason("workspace_not_found"), do: :workspace_not_found
  defp classify_join_reason("workspace_scope_mismatch"), do: :workspace_scope_mismatch
  defp classify_join_reason("workspace_unavailable"), do: :workspace_unavailable
  defp classify_join_reason("unauthorized"), do: :unauthorized
  defp classify_join_reason(:workspace_not_found), do: :workspace_not_found
  defp classify_join_reason(:workspace_scope_mismatch), do: :workspace_scope_mismatch
  defp classify_join_reason(:workspace_unavailable), do: :workspace_unavailable
  defp classify_join_reason(:unauthorized), do: :unauthorized
  defp classify_join_reason(_), do: :unknown

  defp classify_disconnect_reason(:normal), do: :offline
  defp classify_disconnect_reason(:closed), do: :offline
  defp classify_disconnect_reason({:error, :closed}), do: :offline
  defp classify_disconnect_reason({:error, :econnrefused}), do: :network_unavailable
  defp classify_disconnect_reason({:error, :nxdomain}), do: :network_unavailable
  defp classify_disconnect_reason({:error, :timeout}), do: :network_unavailable
  defp classify_disconnect_reason({:error, :etimedout}), do: :network_unavailable
  defp classify_disconnect_reason({:error, :unauthorized}), do: :auth_expired

  defp classify_disconnect_reason(reason) when reason in [:unauthorized, :forbidden],
    do: :auth_expired

  defp classify_disconnect_reason(_), do: :offline

  defp reason_value(%{} = payload) do
    Map.get(payload, "reason") || Map.get(payload, :reason) || payload
  end

  defp reason_value(reason), do: reason

  defp topic(workspace_id), do: "session:" <> workspace_id
  defp workspace_id("session:" <> id), do: id
  defp mobile_cards_topic?(@mobile_cards_topic), do: true
  defp mobile_cards_topic?(_topic), do: false
end
