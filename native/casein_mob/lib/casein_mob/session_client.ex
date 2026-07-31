defmodule CaseinMob.SessionClient do
  @moduledoc """
  Phoenix Channel client for the mobile session companion.

  Runs on the device, holds a single WSS connection to the Casein host's
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
  calls `configure/1`. `CaseinMob.SessionConfig` persists the
  last pairing so the client auto-connects on boot.
  """

  use Slipstream
  require Logger

  alias CaseinMob.ConnectionTiming
  alias CaseinMob.SessionConfig
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

  @doc """
  Acknowledge that accepted cards reached native render-ready state.

  The client owns the one-shot gate so screen remounts and cached replay cannot
  double-count a connection generation.
  """
  @spec cards_render_ready(String.t(), non_neg_integer()) :: :ok
  def cards_render_ready(generation, card_count)
      when is_binary(generation) and is_integer(card_count) and card_count >= 0 do
    cast({:cards_render_ready, generation, card_count})
  end

  def cards_render_ready(_generation, _card_count), do: :ok

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
  Advance a server-issued Attention Inbox marker on the one active origin.
  The server revalidates origin, card, workspace authorization, and marker
  scope; this client method never acts on cached cards.
  """
  @spec attention_viewed(map()) :: :ok
  def attention_viewed(params) when is_map(params) do
    cast({:attention_viewed, params})
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
  def init(opts) do
    boot_context = ConnectionTiming.take_boot_context()

    # Start disconnected. Creds arrive via configure/2, or from a persisted
    # pairing on boot. `subscribers` is topic => MapSet of pids.
    socket =
      Socket.new()
      |> assign(:subscribers, %{})
      |> assign(:subscriber_monitors, %{})
      |> assign(:topic_snapshots, %{})
      |> assign(:url, nil)
      |> assign(:token, nil)
      |> assign(:connecting?, false)
      |> assign(:test_mode?, Keyword.get(opts, :test_mode?, false))
      |> assign(:push_registration_refs, %{})
      |> assign(:card_action_refs, %{})
      |> assign(
        :timing_context,
        boot_context || ConnectionTiming.new_context(:cold)
      )
      |> assign(:render_ready_generation, nil)
      |> assign(:transport_ready?, false)
      |> assign(:accepted_mobile_snapshot_version, nil)
      |> assign(:accepted_mobile_snapshot_origin_id, nil)

    socket =
      case SessionConfig.pairing() do
        # Start the one active transport as soon as durable credentials are
        # restored. The root screen can register watchers while DNS, migrations,
        # and rendering continue; a later watcher joins the already-opening
        # socket rather than serializing connection behind UI mount.
        {:ok, url, token} ->
          socket
          |> restore_configuration(url, token, resolve_dns?: is_nil(boot_context))
          |> timing_stage(:configuration_restored)
          |> request_connect()

        :error ->
          timing_stage(socket, :no_configuration,
            outcome: :skipped,
            reason_code: :no_configuration
          )
      end

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    socket =
      socket
      |> assign(:connecting?, false)
      |> reset_mobile_snapshot_guard()
      |> assign(:transport_ready?, true)
      |> reset_join_statuses()
      |> timing_stage(:transport_connected)

    # A new transport has no server-side channel processes. Slipstream normally
    # closes its local join metadata with the old transport, but a fast native
    # suspend/reconnect can deliver the new connection before that close event.
    # Resetting the local statuses here prevents a stale `:joined` marker from
    # suppressing the authoritative joins on the new connection.
    socket =
      socket.assigns.subscribers
      |> Map.keys()
      |> Enum.reduce(socket, fn topic, acc -> join(acc, topic) end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join(topic, reply, socket) do
    if mobile_cards_topic?(topic) do
      socket = timing_stage(socket, :mobile_join_replied)

      case accept_mobile_snapshot(socket, reply, :join) do
        {:ok, socket, accepted_reply, _baseline?} ->
          socket = cache_topic_snapshot(socket, topic, accepted_reply)
          notify_joined(socket, topic, accepted_reply)
          {:ok, socket}

        {:error, socket} ->
          {:ok, socket}
      end
    else
      socket = cache_topic_snapshot(socket, topic, reply)
      notify_joined(socket, topic, reply)
      {:ok, socket}
    end
  end

  @impl Slipstream
  def handle_message("session:" <> _workspace_id = topic, "snapshot", payload, socket) do
    socket = cache_topic_snapshot(socket, topic, payload)
    notify(socket, topic, {:session_snapshot, workspace_id(topic), payload})
    {:ok, socket}
  end

  def handle_message("session:" <> _workspace_id = topic, "alert", payload, socket) do
    notify(socket, topic, {:session_alert, workspace_id(topic), payload})
    {:ok, socket}
  end

  def handle_message(@mobile_cards_topic = topic, "cards_snapshot", payload, socket) do
    case accept_mobile_snapshot(socket, payload, :push) do
      {:ok, socket, accepted_payload, baseline?} ->
        socket = cache_topic_snapshot(socket, topic, accepted_payload)
        notify(socket, topic, {:mobile_cards_snapshot, accepted_payload})
        if baseline?, do: notify(socket, topic, {:mobile_cards_status, :joined})
        {:ok, socket}

      {:error, socket} ->
        {:ok, socket}
    end
  end

  def handle_message(_topic, "cards_snapshot", _payload, socket), do: {:ok, socket}

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
    {:ok, drop_topic_snapshot(socket, topic)}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    socket =
      socket
      |> assign(:connecting?, false)
      |> assign(:transport_ready?, false)
      |> reset_mobile_snapshot_guard()
      |> begin_timing_cycle(:reconnect)
      |> timing_stage(:disconnected,
        outcome: :failed,
        reason_code: :transport_disconnected
      )

    status = disconnected_status(reason)

    for topic <- Map.keys(socket.assigns.subscribers), do: notify_status(socket, topic, status)
    notify_pending_push_registrations(socket, {:error, status})
    notify_pending_card_actions(socket, {:error, status})

    socket =
      socket
      |> assign(:topic_snapshots, %{})
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
    {:noreply,
     socket
     |> assign(:token, nil)
     |> begin_timing_cycle(:origin_switch)
     |> do_configure(url, token)}
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
     |> clear_subscriber_monitors()
     |> assign(:subscribers, %{})
     |> assign(:topic_snapshots, %{})
     |> assign(:url, nil)
     |> assign(:token, nil)
     |> assign(:connecting?, false)
     |> assign(:transport_ready?, false)
     |> reset_mobile_snapshot_guard()
     |> begin_timing_cycle(:origin_switch)
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

  def handle_cast({:cards_render_ready, generation, card_count}, socket) do
    {:noreply, acknowledge_cards_render_ready(socket, generation, card_count)}
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

  def handle_cast({:attention_viewed, params}, socket) do
    if connected?(socket) and joined?(socket, @mobile_cards_topic) do
      _ = push(socket, @mobile_cards_topic, "attention_viewed", params)
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
  def handle_info({:DOWN, ref, :process, pid, _reason}, socket) do
    case Map.get(socket.assigns.subscriber_monitors, pid) do
      ^ref ->
        # A screen went away — forget its one monitor, drop it from every topic,
        # and leave topics that empty out.
        socket =
          socket
          |> assign(:subscriber_monitors, Map.delete(socket.assigns.subscriber_monitors, pid))
          |> then(fn socket ->
            socket.assigns.subscribers
            |> Map.keys()
            |> Enum.reduce(socket, fn topic, acc -> drop_subscriber(acc, topic, pid) end)
          end)

        {:noreply, socket}

      _other ->
        {:noreply, socket}
    end
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
    subscribers =
      Map.update(
        socket.assigns.subscribers,
        topic,
        MapSet.new([subscriber]),
        &MapSet.put(&1, subscriber)
      )

    socket =
      socket
      |> ensure_subscriber_monitor(subscriber)
      |> assign(:subscribers, subscribers)

    cond do
      not connected?(socket) -> ensure_connection_requested(socket)
      joined?(socket, topic) -> replay_joined_topic(socket, topic, subscriber)
      true -> join(socket, topic)
    end
  end

  defp do_configure(socket, url, token) do
    changed? = socket.assigns.url != url or socket.assigns.token != token
    origin_changed? = different_origin?(socket.assigns.url, url)
    had_configuration? = is_binary(socket.assigns.url)

    socket =
      socket
      |> maybe_disconnect_for_reconfigure(changed?)
      |> configure_timing_cycle(changed?, origin_changed?, had_configuration?)

    dns_result = resolve_host(url)

    socket =
      socket
      |> timing_stage(:dns_resolved, dns_timing_opts(dns_result))
      |> assign(:url, url)
      |> assign(:token, token)

    if changed?, do: request_connect(socket), else: ensure_connection_requested(socket)
  end

  defp maybe_disconnect_for_reconfigure(socket, false), do: socket

  defp maybe_disconnect_for_reconfigure(socket, true) do
    if connected?(socket) or socket.assigns.connecting? do
      socket
      |> disconnect()
      |> assign(:connecting?, false)
    else
      socket
    end
  end

  defp configure_timing_cycle(socket, _changed?, true, _had_configuration?) do
    socket
    |> clear_origin_state()
    |> begin_timing_cycle(:origin_switch)
  end

  defp configure_timing_cycle(socket, true, false, true) do
    case get_in(socket.assigns, [:timing_context, :cycle]) do
      :origin_switch -> socket
      _other_cycle -> begin_timing_cycle(socket, :reconnect)
    end
  end

  defp configure_timing_cycle(socket, _changed?, _origin_changed?, _had_configuration?),
    do: socket

  defp restore_configuration(socket, url, token, opts) do
    socket =
      if Keyword.get(opts, :resolve_dns?, true) do
        timing_stage(socket, :dns_resolved, dns_timing_opts(resolve_host(url)))
      else
        socket
      end

    socket
    |> assign(:url, url)
    |> assign(:token, token)
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
    |> clear_subscriber_monitors()
    |> assign(:subscribers, %{})
    |> assign(:topic_snapshots, %{})
    |> assign(:transport_ready?, false)
    |> reset_mobile_snapshot_guard()
    |> assign(:push_registration_refs, %{})
    |> assign(:card_action_refs, %{})
  end

  defp cache_topic_snapshot(socket, topic, payload) do
    snapshots = Map.put(socket.assigns[:topic_snapshots] || %{}, topic, payload)
    assign(socket, :topic_snapshots, snapshots)
  end

  defp accept_mobile_snapshot(socket, payload, source) when is_map(payload) do
    version = payload_value(payload, :version)
    card_count = snapshot_card_count(payload)
    sample_size? = source == :join

    socket =
      timing_stage(socket, :snapshot_received,
        card_count: card_count,
        snapshot_version: version,
        snapshot_json_bytes:
          if(sample_size?, do: ConnectionTiming.snapshot_json_bytes(payload), else: nil)
      )

    with :ok <- validate_transport_ready(socket),
         :ok <- validate_snapshot_generation(socket, payload),
         :ok <- validate_snapshot_cycle(socket, payload),
         {:ok, version} <- validate_snapshot_version(version),
         {:ok, socket, origin_id} <- validate_snapshot_origin(socket, payload),
         :ok <- validate_snapshot_order(socket, version) do
      baseline? = is_nil(socket.assigns.accepted_mobile_snapshot_version)

      socket =
        socket
        |> assign(:accepted_mobile_snapshot_version, version)
        |> assign(:accepted_mobile_snapshot_origin_id, origin_id)
        |> timing_stage(:snapshot_accepted,
          card_count: card_count,
          snapshot_version: version
        )

      accepted_payload =
        ConnectionTiming.decorate_snapshot(payload, socket.assigns.timing_context)

      {:ok, socket, accepted_payload, baseline?}
    else
      {:error, reason} ->
        socket =
          timing_stage(socket, :snapshot_rejected,
            outcome: :failed,
            reason_code: reason,
            card_count: card_count,
            snapshot_version: version
          )

        {:error, socket}
    end
  end

  defp accept_mobile_snapshot(socket, _payload, _source) do
    socket = timing_stage(socket, :snapshot_received)

    {:error,
     timing_stage(socket, :snapshot_rejected,
       outcome: :failed,
       reason_code: :invalid_payload
     )}
  end

  defp validate_transport_ready(%{assigns: %{transport_ready?: true}}), do: :ok
  defp validate_transport_ready(_socket), do: {:error, :transport_not_ready}

  defp validate_snapshot_generation(socket, payload) do
    expected = get_in(socket.assigns, [:timing_context, :generation])
    received = payload_value(payload, :connection_generation)

    if is_binary(expected) and byte_size(expected) == 22 and received == expected,
      do: :ok,
      else: {:error, :connection_generation_mismatch}
  end

  defp validate_snapshot_cycle(socket, payload) do
    expected =
      socket.assigns
      |> get_in([:timing_context, :cycle])
      |> then(fn
        cycle when cycle in [:cold, :reconnect, :origin_switch] -> Atom.to_string(cycle)
        _ -> nil
      end)

    if payload_value(payload, :connection_cycle) == expected,
      do: :ok,
      else: {:error, :connection_cycle_mismatch}
  end

  defp validate_snapshot_version(version) when is_integer(version) and version >= 0,
    do: {:ok, version}

  defp validate_snapshot_version(_version), do: {:error, :invalid_snapshot_version}

  defp validate_snapshot_origin(socket, payload) do
    descriptor = payload_value(payload, :origin)
    origin_id = if is_map(descriptor), do: payload_value(descriptor, :id)

    if is_binary(origin_id) and origin_id != "" do
      validate_snapshot_origin_id(
        socket,
        descriptor,
        origin_id,
        socket.assigns.accepted_mobile_snapshot_origin_id,
        Map.get(socket.assigns, :expected_mobile_snapshot_origin_id)
      )
    else
      {:error, :invalid_origin}
    end
  end

  defp validate_snapshot_origin_id(socket, _descriptor, origin_id, accepted, _expected)
       when is_binary(accepted) and accepted != "" do
    if accepted == origin_id,
      do: {:ok, socket, origin_id},
      else: {:error, :origin_mismatch}
  end

  defp validate_snapshot_origin_id(socket, _descriptor, origin_id, _accepted, origin_id),
    do: {:ok, socket, origin_id}

  defp validate_snapshot_origin_id(socket, descriptor, origin_id, _accepted, _expected),
    do: reconcile_snapshot_origin(socket, descriptor, origin_id)

  defp reconcile_snapshot_origin(socket, descriptor, origin_id) do
    case safe_reconcile_active_origin(descriptor) do
      {:ok, %{origin_id: ^origin_id} = profile} ->
        {:ok, socket, profile.origin_id}

      {:ok, _other_profile} ->
        {:error, :origin_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_reconcile_active_origin(descriptor) do
    SessionConfig.reconcile_active_origin(descriptor)
  rescue
    _ -> {:error, :state_unavailable}
  catch
    :exit, _reason -> {:error, :state_unavailable}
  end

  defp validate_snapshot_order(socket, version) do
    case socket.assigns.accepted_mobile_snapshot_version do
      nil -> :ok
      accepted when version < accepted -> {:error, :snapshot_version_regression}
      _accepted -> :ok
    end
  end

  defp snapshot_card_count(payload) do
    case payload_value(payload, :cards) do
      cards when is_list(cards) -> Enum.count(cards, &is_map/1)
      _ -> 0
    end
  end

  defp payload_value(payload, key) when is_map(payload) and is_atom(key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp reset_mobile_snapshot_guard(socket) do
    expected_origin_id =
      case active_origin_id() do
        origin_id when is_binary(origin_id) and origin_id != "" ->
          origin_id

        _unavailable ->
          Map.get(socket.assigns, :expected_mobile_snapshot_origin_id)
      end

    socket
    |> assign(:accepted_mobile_snapshot_version, nil)
    |> assign(:accepted_mobile_snapshot_origin_id, nil)
    |> assign(:expected_mobile_snapshot_origin_id, expected_origin_id)
  end

  defp active_origin_id do
    case SessionConfig.connection() do
      {:ok, %{origin_id: origin_id}} when is_binary(origin_id) -> origin_id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _reason -> nil
  end

  defp drop_topic_snapshot(socket, topic) do
    snapshots = Map.delete(socket.assigns[:topic_snapshots] || %{}, topic)
    assign(socket, :topic_snapshots, snapshots)
  end

  defp replay_joined_topic(socket, topic, subscriber) do
    case Map.get(socket.assigns[:topic_snapshots] || %{}, topic) do
      nil ->
        socket

      snapshot ->
        notify_joined_subscriber(topic, subscriber, snapshot)
        socket
    end
  end

  defp notify_joined_subscriber("session:" <> workspace_id, subscriber, snapshot) do
    send(subscriber, {:session_snapshot, workspace_id, snapshot})
    send(subscriber, {:session_status, workspace_id, :joined})
  end

  defp notify_joined_subscriber(topic, subscriber, snapshot) do
    if mobile_cards_topic?(topic) do
      send(subscriber, {:mobile_cards_snapshot, snapshot})
      send(subscriber, {:mobile_cards_status, :joined})
    end
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

  defp reset_join_statuses(socket) do
    joins =
      Map.new(socket.joins, fn {topic, join} ->
        {topic, %{join | status: :closed}}
      end)

    %{socket | joins: joins}
  end

  # iOS needs its native resolver for some public and VPN-provided hostnames.
  # Resolve each configured origin, not only the profile that happened to be
  # active when the app booted.
  defp resolve_host(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" ->
        resolve_hostname(host)

      _missing ->
        {:error, :invalid_url}
    end
  rescue
    _ -> {:error, :resolution_failed}
  catch
    :exit, _reason -> {:error, :resolution_failed}
  end

  defp resolve_hostname(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} ->
        {:skip, :ip_literal}

      {:error, _reason} ->
        case Mob.DNS.resolve(host) do
          {:ok, _address} -> {:ok, :resolved}
          {:error, _reason} -> {:error, :resolution_failed}
          _unexpected -> {:error, :resolution_failed}
        end
    end
  rescue
    _ -> {:error, :resolution_failed}
  catch
    :exit, _reason -> {:error, :resolution_failed}
  end

  defp dns_timing_opts({:ok, :resolved}),
    do: [outcome: :succeeded, reason_code: :dns_resolved]

  defp dns_timing_opts({:skip, :ip_literal}),
    do: [outcome: :skipped, reason_code: :dns_ip_literal]

  defp dns_timing_opts({:error, :invalid_url}),
    do: [outcome: :failed, reason_code: :dns_invalid_url]

  defp dns_timing_opts(_failure),
    do: [outcome: :failed, reason_code: :dns_resolution_failed]

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
    socket = ensure_timing_context(socket, :cold)
    socket = timing_stage(socket, :connect_requested, outcome: :started)

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
    socket = refresh_reconnect_config(socket)
    socket = timing_stage(socket, :reconnect_requested, outcome: :started)

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

  defp acknowledge_cards_render_ready(socket, generation, card_count) do
    current_generation = get_in(socket.assigns, [:timing_context, :generation])
    acknowledged_generation = Map.get(socket.assigns, :render_ready_generation)

    if generation == current_generation and acknowledged_generation != current_generation do
      socket
      |> timing_stage(:first_cards_render_ready, card_count: card_count)
      |> assign(:render_ready_generation, current_generation)
    else
      socket
    end
  end

  defp connect_opts(socket) do
    uri =
      ws_uri(
        socket.assigns.url,
        socket.assigns.token,
        socket.assigns.timing_context
      )

    opts = [
      uri: uri,
      mint_opts: mint_opts(uri)
    ]

    if Map.get(socket.assigns, :test_mode?, false) do
      opts
      |> Keyword.put(:test_mode?, true)
      |> Keyword.put(:reconnect_after_msec, [0])
    else
      Keyword.put(opts, :reconnect_after_msec, [250, 500, 1_000, 2_000])
    end
  end

  defp begin_timing_cycle(socket, cycle) do
    socket
    |> assign(:timing_context, ConnectionTiming.new_context(cycle))
    |> assign(:render_ready_generation, nil)
  end

  defp ensure_timing_context(socket, fallback_cycle) do
    case Map.get(socket.assigns, :timing_context) do
      %{generation: generation} when is_binary(generation) -> socket
      _ -> begin_timing_cycle(socket, fallback_cycle)
    end
  end

  defp timing_stage(socket, stage, opts \\ []) do
    case Map.get(socket.assigns, :timing_context) do
      %{generation: _generation} = context ->
        assign(socket, :timing_context, ConnectionTiming.record(context, stage, opts))

      _ ->
        socket
    end
  end

  defp refresh_reconnect_config(%{channel_config: nil} = socket), do: socket

  defp refresh_reconnect_config(socket) do
    uri =
      ws_uri(
        socket.assigns.url,
        socket.assigns.token,
        socket.assigns.timing_context
      )

    %{socket | channel_config: %{socket.channel_config | uri: URI.parse(uri)}}
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
    case :code.priv_dir(:casein_mob) do
      priv_dir when is_list(priv_dir) -> Path.join([List.to_string(priv_dir), relative_path])
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  end

  # Accepts either a base host URL ("https://host") or an explicit socket URL.
  # Normalizes to the Phoenix websocket endpoint with the auth token in query.
  defp ws_uri(url, token, timing_context) do
    uri = URI.parse(url)
    scheme = if uri.scheme in ["https", "wss"], do: "wss", else: "ws"
    path = if uri.path in [nil, "", "/"], do: "/socket/websocket", else: ensure_ws_path(uri.path)

    query = %{
      "token" => token,
      "connection_generation" => timing_context.generation,
      "connection_cycle" => Atom.to_string(timing_context.cycle)
    }

    %URI{uri | scheme: scheme, path: path, query: URI.encode_query(query)}
    |> URI.to_string()
  end

  defp ensure_ws_path(path) do
    if String.ends_with?(path, "/websocket"),
      do: path,
      else: String.trim_trailing(path, "/") <> "/websocket"
  end

  defp drop_subscriber(socket, topic, subscriber) do
    socket =
      case Map.get(socket.assigns.subscribers, topic) do
        nil ->
          socket

        pids ->
          remaining = MapSet.delete(pids, subscriber)

          if MapSet.size(remaining) == 0 do
            socket =
              socket
              |> assign(:subscribers, Map.delete(socket.assigns.subscribers, topic))
              |> assign(:topic_snapshots, Map.delete(socket.assigns.topic_snapshots, topic))

            if joined?(socket, topic), do: leave(socket, topic), else: socket
          else
            assign(socket, :subscribers, Map.put(socket.assigns.subscribers, topic, remaining))
          end
      end

    maybe_demonitor_subscriber(socket, subscriber)
  end

  defp ensure_subscriber_monitor(socket, subscriber) do
    if Map.has_key?(socket.assigns.subscriber_monitors, subscriber) do
      socket
    else
      monitor = Process.monitor(subscriber)

      assign(
        socket,
        :subscriber_monitors,
        Map.put(socket.assigns.subscriber_monitors, subscriber, monitor)
      )
    end
  end

  defp maybe_demonitor_subscriber(socket, subscriber) do
    subscribed? =
      Enum.any?(socket.assigns.subscribers, fn {_topic, pids} ->
        MapSet.member?(pids, subscriber)
      end)

    if subscribed? do
      socket
    else
      case Map.pop(socket.assigns.subscriber_monitors, subscriber) do
        {nil, _monitors} ->
          socket

        {monitor, monitors} ->
          Process.demonitor(monitor, [:flush])
          assign(socket, :subscriber_monitors, monitors)
      end
    end
  end

  defp clear_subscriber_monitors(socket) do
    Enum.each(socket.assigns.subscriber_monitors, fn {_subscriber, monitor} ->
      Process.demonitor(monitor, [:flush])
    end)

    assign(socket, :subscriber_monitors, %{})
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
