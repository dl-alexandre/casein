defmodule CaseinMob.SessionClientTest do
  use ExUnit.Case, async: false

  alias CaseinMob.ConnectionTiming
  alias CaseinMob.MobileTerminalStream
  alias CaseinMob.OriginIdentity
  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig
  alias Slipstream.Socket

  setup do
    if Process.whereis(Mob.State) == nil do
      start_supervised!(Mob.State)
    end

    SessionConfig.clear_all()
    :ok
  end

  test "mobile card topic join and pushes notify subscribers" do
    socket = socket_with_subscriber("mobile:user:me", self())
    snapshot = mobile_snapshot(socket, 4, [%{"id" => "needs_review:ws-1:run-1"}])

    assert {:ok, joined_socket} = SessionClient.handle_join("mobile:user:me", snapshot, socket)
    assert joined_socket.assigns.accepted_mobile_snapshot_version == 4
    assert joined_socket.assigns.topic_snapshots["mobile:user:me"]["cards"] == snapshot["cards"]

    assert_receive {:mobile_cards_snapshot, received}
    assert received["cards"] == snapshot["cards"]
    assert_receive {:mobile_cards_status, :joined}

    next_snapshot =
      mobile_snapshot(joined_socket, 4, [], %{
        "live_work" => %{"status" => "authoritative"}
      })

    assert {:ok, updated_socket} =
             SessionClient.handle_message(
               "mobile:user:me",
               "cards_snapshot",
               next_snapshot,
               joined_socket
             )

    assert updated_socket.assigns.accepted_mobile_snapshot_version == 4

    assert updated_socket.assigns.topic_snapshots["mobile:user:me"]["live_work"] ==
             next_snapshot["live_work"]

    assert_receive {:mobile_cards_snapshot, received}
    assert received["live_work"] == next_snapshot["live_work"]
  end

  test "mobile card topic close reports mobile status without workspace id" do
    socket = socket_with_subscriber("mobile:user:me", self())

    assert {:ok, ^socket} =
             SessionClient.handle_topic_close(
               "mobile:user:me",
               {:error, %{"reason" => "unauthorized"}},
               socket
             )

    assert_receive {:mobile_cards_status, {:error, :unauthorized}}
  end

  test "disconnect fans out status to mobile card and workspace subscribers" do
    socket =
      socket_with_subscribers(%{
        "mobile:user:me" => MapSet.new([self()]),
        "session:ws-1" => MapSet.new([self()])
      })
      |> Socket.assign(:topic_snapshots, %{
        "mobile:user:me" => %{"cards" => [%{"id" => "old-card"}]}
      })

    assert {:ok, socket} = SessionClient.handle_disconnect({:error, :econnrefused}, socket)
    assert socket.assigns.topic_snapshots == %{}

    assert_receive {:mobile_cards_status, {:disconnected, :network_unavailable}}
    assert_receive {:session_status, "ws-1", {:disconnected, :network_unavailable}}
  end

  test "disconnect is recorded on the closing generation without inventing an idle reconnect" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_feed_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    socket = socket_with_subscribers(%{})
    closing_generation = socket.assigns.timing_context.generation

    assert {:ok, disconnected} = SessionClient.handle_disconnect(:closed, socket)

    assert disconnected.assigns.timing_context.generation == closing_generation
    assert disconnected.assigns.timing_context.cycle == :cold

    assert_receive {:feed_stage, _measurements,
                    %{
                      stage: :disconnected,
                      cycle: :cold,
                      connection_generation: ^closing_generation
                    }}
  end

  test "a watched socket without transport configuration does not invent a reconnect" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_feed_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "http://127.0.0.1:1")
      |> Socket.assign(:token, "token")

    assert socket.channel_config == nil
    closing_generation = socket.assigns.timing_context.generation

    assert {:ok, disconnected} = SessionClient.handle_disconnect(:closed, socket)

    assert disconnected.assigns.timing_context.generation == closing_generation
    assert disconnected.assigns.timing_context.cycle == :cold
    refute disconnected.assigns.connecting?

    assert_receive {:feed_stage, _measurements,
                    %{
                      stage: :disconnected,
                      cycle: :cold,
                      connection_generation: ^closing_generation
                    }}

    refute_receive {:feed_stage, _measurements, %{stage: :connect_requested}}
  end

  test "watching after an idle disconnect starts a fresh reconnect generation" do
    socket = socket_with_subscribers(%{}) |> Socket.assign(:test_mode?, true)

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:configure, "http://127.0.0.1:1", "token"},
               socket
             )

    closing_generation = socket.assigns.timing_context.generation
    assert {:ok, idle} = SessionClient.handle_disconnect(:closed, socket)
    assert idle.assigns.timing_context.generation == closing_generation

    assert {:noreply, reconnecting} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, idle)

    reconnect_generation = reconnecting.assigns.timing_context.generation
    refute reconnect_generation == closing_generation
    assert reconnecting.assigns.timing_context.cycle == :reconnect
    assert reconnecting.assigns.connecting?

    query = URI.decode_query(reconnecting.channel_config.uri.query)
    assert query["connection_generation"] == reconnect_generation
    assert query["connection_cycle"] == "reconnect"
  end

  test "watching after an expired idle disconnect still starts a fresh reconnect generation" do
    socket = socket_with_subscribers(%{}) |> Socket.assign(:test_mode?, true)

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:configure, "http://127.0.0.1:1", "token"},
               socket
             )

    closing_context = socket.assigns.timing_context
    max_elapsed_microseconds = 2_147_483_647 * 1_000

    expired_context = %{
      closing_context
      | started_at: closing_context.started_at - max_elapsed_microseconds - 1
    }

    socket = Socket.assign(socket, :timing_context, expired_context)
    closing_generation = expired_context.generation

    assert {:ok, idle} = SessionClient.handle_disconnect(:closed, socket)
    assert idle.assigns.timing_context.generation == closing_generation
    refute MapSet.member?(idle.assigns.timing_context.seen_stages, :disconnected)
    assert idle.assigns.reconnect_generation_required?

    assert {:noreply, reconnecting} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, idle)

    reconnect_generation = reconnecting.assigns.timing_context.generation
    refute reconnect_generation == closing_generation
    assert reconnecting.assigns.timing_context.cycle == :reconnect
    refute reconnecting.assigns.reconnect_generation_required?
    assert reconnecting.assigns.connecting?

    query = URI.decode_query(reconnecting.channel_config.uri.query)
    assert query["connection_generation"] == reconnect_generation
    assert query["connection_cycle"] == "reconnect"
  end

  test "a requested reconnect closes the old generation before starting the new one" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_feed_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:test_mode?, true)

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:configure, "http://127.0.0.1:1", "token"},
               socket
             )

    closing_generation = socket.assigns.timing_context.generation
    assert socket.assigns.connecting?
    assert socket.channel_config.mint_opts == [protocols: [:http1]]

    assert {:ok, reconnecting} = SessionClient.handle_disconnect(:closed, socket)

    next_generation = reconnecting.assigns.timing_context.generation
    refute next_generation == closing_generation
    assert reconnecting.assigns.timing_context.cycle == :reconnect
    assert reconnecting.assigns.connecting?
    assert reconnecting.channel_config.mint_opts == [protocols: [:http1]]

    assert_receive {:feed_stage, _measurements,
                    %{
                      stage: :disconnected,
                      cycle: :cold,
                      connection_generation: ^closing_generation
                    }}

    assert_receive {:feed_stage, _measurements,
                    %{
                      stage: :connect_requested,
                      cycle: :reconnect,
                      connection_generation: ^next_generation
                    }}
  end

  test "secure reconnect refreshes the TCP timing target to the new generation" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:test_mode?, true)

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:configure, "https://127.0.0.1:1", "token"},
               socket
             )

    initial_generation = socket.assigns.timing_context.generation
    initial_transport_opts = socket.channel_config.mint_opts[:transport_opts]

    assert initial_transport_opts[:cb_info] ==
             {CaseinMob.TimedTCP, :tcp, :tcp_closed, :tcp_error, :tcp_passive}

    assert initial_transport_opts[:casein_timing] == {self(), initial_generation}

    assert {:ok, reconnecting} = SessionClient.handle_disconnect(:closed, socket)
    reconnect_generation = reconnecting.assigns.timing_context.generation
    refute reconnect_generation == initial_generation

    reconnect_transport_opts = reconnecting.channel_config.mint_opts[:transport_opts]
    assert reconnect_transport_opts[:casein_timing] == {self(), reconnect_generation}

    query = URI.decode_query(reconnecting.channel_config.uri.query)
    assert query["connection_generation"] == reconnect_generation
  end

  test "only current-generation TCP observations advance timing" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_feed_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    socket = socket_with_subscribers(%{})
    generation = socket.assigns.timing_context.generation
    started_at = System.monotonic_time()

    assert {:noreply, socket} =
             SessionClient.handle_info(
               {:casein_tcp_timing, generation, :tcp_connect_started, started_at},
               socket
             )

    assert_receive {:feed_stage, _measurements,
                    %{
                      stage: :tcp_connect_started,
                      outcome: :started,
                      connection_generation: ^generation
                    }}

    connected_at = System.monotonic_time()

    assert {:noreply, socket} =
             SessionClient.handle_info(
               {:casein_tcp_timing, generation, :tcp_connected, connected_at},
               socket
             )

    assert_receive {:feed_stage, _measurements,
                    %{
                      stage: :tcp_connected,
                      outcome: :succeeded,
                      connection_generation: ^generation
                    }}

    assert {:noreply, ^socket} =
             SessionClient.handle_info(
               {:casein_tcp_timing, "AAAAAAAAAAAAAAAAAAAAAA", :tcp_connected,
                System.monotonic_time()},
               socket
             )

    assert {:noreply, _socket} =
             SessionClient.handle_info(
               {:casein_tcp_timing, generation, :tcp_connected, System.monotonic_time()},
               socket
             )

    refute_receive {:feed_stage, _measurements, %{stage: :tcp_connected}}
  end

  test "mobile card stream reports disconnected then joined after recovery" do
    socket = socket_with_subscriber("mobile:user:me", self())

    assert {:ok, socket} = SessionClient.handle_disconnect(:closed, socket)
    assert_receive {:mobile_cards_status, :disconnected}

    assert {:ok, socket} = SessionClient.handle_connect(socket)
    snapshot = mobile_snapshot(socket, 1, [%{"id" => "in_progress:ws-1:run-1"}])

    assert {:ok, recovered} = SessionClient.handle_join("mobile:user:me", snapshot, socket)
    assert recovered.assigns.accepted_mobile_snapshot_version == 1

    assert_receive {:mobile_cards_snapshot, received}
    assert received["cards"] == snapshot["cards"]
    assert_receive {:mobile_cards_status, :joined}
  end

  test "rewatching an already joined mobile card topic replays its authoritative snapshot" do
    topic = "mobile:user:me"
    base_socket = socket_with_subscriber(topic, self())

    snapshot =
      base_socket
      |> mobile_snapshot(1, [%{"id" => "clarification:ws-1:event-1"}])
      |> ConnectionTiming.decorate_snapshot(base_socket.assigns.timing_context)

    socket =
      base_socket
      |> Map.put(:channel_pid, self())
      |> Socket.assign(:topic_snapshots, %{topic => snapshot})
      |> Socket.put_join_config(topic, %{})
      |> put_in([Access.key(:joins), topic, Access.key(:status)], :joined)

    assert {:noreply, watched_socket} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, socket)

    assert is_reference(watched_socket.assigns.subscriber_monitors[self()])
    assert_receive {:mobile_cards_snapshot, received}
    assert received["cards"] == snapshot["cards"]
    assert_receive {:mobile_cards_status, :joined}
  end

  test "a fresh transport rejoins subscribers despite stale local joined metadata" do
    socket =
      %{
        "mobile:user:me" => MapSet.new([self()]),
        "session:ws-1" => MapSet.new([self()])
      }
      |> socket_with_subscribers()
      |> Map.put(:channel_pid, self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> Socket.put_join_config("session:ws-1", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> put_in([Access.key(:joins), "session:ws-1", Access.key(:status)], :joined)

    assert {:ok, socket} = SessionClient.handle_connect(socket)

    # Slipstream retains the prior closed join config until its join reply, but
    # both join commands must be emitted for the new transport.
    assert Socket.join_status(socket, "mobile:user:me") == :closed
    assert Socket.join_status(socket, "session:ws-1") == :closed

    assert_receive {:__slipstream_command__,
                    %Slipstream.Commands.JoinTopic{topic: "mobile:user:me"}}

    assert_receive {:__slipstream_command__,
                    %Slipstream.Commands.JoinTopic{topic: "session:ws-1"}}
  end

  test "subscriber process exit removes mobile card watchers" do
    other = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(other, :kill) end)
    monitor = make_ref()

    socket =
      socket_with_subscribers(%{
        "mobile:user:me" => MapSet.new([self(), other]),
        "session:ws-1" => MapSet.new([self()])
      })
      |> Socket.assign(:subscriber_monitors, %{self() => monitor, other => make_ref()})
      |> Socket.assign(:topic_snapshots, %{
        "mobile:user:me" => %{"cards" => [%{"id" => "card-1"}]},
        "session:ws-1" => %{"sessions" => [%{"id" => "session-1"}]}
      })

    assert {:noreply, socket} =
             SessionClient.handle_info({:DOWN, monitor, :process, self(), :normal}, socket)

    assert socket.assigns.subscribers == %{
             "mobile:user:me" => MapSet.new([other])
           }

    assert Map.keys(socket.assigns.subscriber_monitors) == [other]

    assert socket.assigns.topic_snapshots == %{
             "mobile:user:me" => %{"cards" => [%{"id" => "card-1"}]}
           }
  end

  test "repeated watch and final unwatch own one bounded subscriber monitor" do
    socket = socket_with_subscribers(%{})

    assert {:noreply, socket} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, socket)

    monitor = socket.assigns.subscriber_monitors[self()]
    assert is_reference(monitor)

    assert {:noreply, socket} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, socket)

    assert socket.assigns.subscriber_monitors == %{self() => monitor}

    assert {:noreply, socket} =
             SessionClient.handle_cast({:unwatch_mobile_cards, self()}, socket)

    assert socket.assigns.subscribers == %{}
    assert socket.assigns.subscriber_monitors == %{}
    refute Process.demonitor(monitor, [:info])
  end

  test "clearing pairing flushes subscriber monitors across topics" do
    monitor = Process.monitor(self())

    socket =
      socket_with_subscribers(%{
        "mobile:user:me" => MapSet.new([self()]),
        "session:ws-1" => MapSet.new([self()])
      })
      |> Socket.assign(:subscriber_monitors, %{self() => monitor})

    assert {:noreply, socket} = SessionClient.handle_cast(:clear_pairing, socket)

    assert socket.assigns.subscribers == %{}
    assert socket.assigns.subscriber_monitors == %{}
    refute Process.demonitor(monitor, [:info])
  end

  test "push registration reply notifies subscribers after server acknowledgement" do
    socket =
      %{
        "mobile:user:me" => MapSet.new([self()]),
        "session:ws-1" => MapSet.new([self()])
      }
      |> socket_with_subscribers()
      |> Socket.assign(:push_registration_refs, %{
        "ref-1" => %{workspace_id: "ws-1", topic: "mobile:user:me"}
      })

    assert {:ok, socket} = SessionClient.handle_reply("ref-1", :ok, socket)

    assert socket.assigns.push_registration_refs == %{}
    assert_receive {:push_registration_status, "ws-1", :registered}
    refute_receive {:push_registration_status, "ws-1", :registered}
  end

  test "user push registration reply notifies subscribers after server acknowledgement" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:push_registration_refs, %{
        "ref-1" => %{scope: :user, topic: "mobile:user:me"}
      })

    assert {:ok, socket} = SessionClient.handle_reply("ref-1", :ok, socket)

    assert socket.assigns.push_registration_refs == %{}
    assert_receive {:push_registration_status, :user, :registered}
  end

  test "push registration waits for all pending workspace acknowledgements" do
    socket =
      %{
        "mobile:user:me" => MapSet.new([self()]),
        "session:ws-1" => MapSet.new([self()])
      }
      |> socket_with_subscribers()
      |> Socket.assign(:push_registration_refs, %{
        "ref-1" => %{workspace_id: "ws-1", topic: "mobile:user:me"},
        "ref-2" => %{workspace_id: "ws-1", topic: "session:ws-1"}
      })

    assert {:ok, socket} = SessionClient.handle_reply("ref-1", :ok, socket)

    assert socket.assigns.push_registration_refs == %{
             "ref-2" => %{workspace_id: "ws-1", topic: "session:ws-1"}
           }

    refute_receive {:push_registration_status, "ws-1", :registered}

    assert {:ok, socket} = SessionClient.handle_reply("ref-2", :ok, socket)

    assert socket.assigns.push_registration_refs == %{}
    assert_receive {:push_registration_status, "ws-1", :registered}
  end

  test "push registration error reply notifies subscribers" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:push_registration_refs, %{
        "ref-1" => %{workspace_id: "ws-1", topic: "mobile:user:me"}
      })

    assert {:ok, socket} =
             SessionClient.handle_reply(
               "ref-1",
               {:error, %{"reason" => "workspace_scope_mismatch"}},
               socket
             )

    assert socket.assigns.push_registration_refs == %{}
    assert_receive {:push_registration_status, "ws-1", {:error, "workspace_scope_mismatch"}}
  end

  test "disconnect clears pending push registrations" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:push_registration_refs, %{
        "ref-1" => %{workspace_id: "ws-1", topic: "mobile:user:me"}
      })

    assert {:ok, socket} = SessionClient.handle_disconnect(:closed, socket)

    assert socket.assigns.push_registration_refs == %{}
    assert_receive {:mobile_cards_status, :disconnected}
    assert_receive {:push_registration_status, "ws-1", {:error, :disconnected}}
  end

  test "disconnect clears pending user push registrations" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:push_registration_refs, %{
        "ref-1" => %{scope: :user, topic: "mobile:user:me"}
      })

    assert {:ok, socket} = SessionClient.handle_disconnect(:closed, socket)

    assert socket.assigns.push_registration_refs == %{}
    assert_receive {:mobile_cards_status, :disconnected}
    assert_receive {:push_registration_status, :user, {:error, :disconnected}}
  end

  test "plain http pairing uses a TCP websocket connection without TLS transport options" do
    socket = socket_with_subscribers(%{})

    assert {:noreply, socket} =
             SessionClient.handle_cast({:configure, "http://127.0.0.1:1", "token"}, socket)

    assert socket.assigns.url == "http://127.0.0.1:1"
    assert socket.assigns.token == "token"
    assert socket.assigns.connecting?
  end

  test "switching origins clears old topics and pending origin-owned work" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "https://old.example")
      |> Socket.assign(:token, "old-token")
      |> Socket.assign(:push_registration_refs, %{
        "push-ref" => %{scope: :user, topic: "mobile:user:me"}
      })
      |> Socket.assign(:card_action_refs, %{
        "action-ref" => %{card_id: "needs_review:old-ws:run-1"}
      })
      |> Socket.assign(:topic_snapshots, %{
        "mobile:user:me" => %{"cards" => [%{"id" => "old-card"}]}
      })
      |> Socket.assign(:accepted_mobile_snapshot_version, 22)
      |> Socket.assign(:accepted_mobile_snapshot_origin_id, "origin-1")

    prior_generation = socket.assigns.timing_context.generation

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:activate_origin, "http://127.0.0.1:1", "new-token"},
               socket
             )

    assert socket.assigns.url == "http://127.0.0.1:1"
    assert socket.assigns.token == "new-token"
    assert socket.assigns.subscribers == %{}
    assert socket.assigns.topic_snapshots == %{}
    assert socket.assigns.push_registration_refs == %{}
    assert socket.assigns.card_action_refs == %{}
    assert socket.assigns.accepted_mobile_snapshot_version == nil
    assert socket.assigns.accepted_mobile_snapshot_origin_id == nil
    assert socket.assigns.timing_context.cycle == :origin_switch
    refute socket.assigns.timing_context.generation == prior_generation
    origin_switch_generation = socket.assigns.timing_context.generation

    assert {:noreply, reactivated} =
             SessionClient.handle_cast(
               {:activate_origin, "http://127.0.0.1:1", "new-token"},
               socket
             )

    assert reactivated.assigns.timing_context.cycle == :origin_switch
    assert reactivated.assigns.timing_context.generation == origin_switch_generation
    assert reactivated.assigns.pending_configuration.force_reconnect?

    assert_receive {:mobile_cards_status, :disconnected}
    assert_receive {:push_registration_status, :user, {:error, :host_switched}}

    assert_receive {:card_action_result, "needs_review:old-ws:run-1", {:error, :host_switched}}
  end

  test "stable origin identity distinguishes saved origins sharing one endpoint" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "https://shared.example")
      |> Socket.assign(:token, "shared-token")
      |> Socket.assign(:configured_origin_id, "origin-old")

    prior_generation = socket.assigns.timing_context.generation

    assert {:noreply, switched} =
             SessionClient.handle_cast(
               {:activate_origin, "https://shared.example", "shared-token", "origin-new"},
               socket
             )

    assert switched.assigns.configured_origin_id == "origin-new"
    assert switched.assigns.subscribers == %{}
    assert switched.assigns.timing_context.cycle == :origin_switch
    refute switched.assigns.timing_context.generation == prior_generation
  end

  test "canonical URL fallback treats equivalent endpoint forms as one origin" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "https://EXAMPLE.com:443/socket/websocket?old=1")
      |> Socket.assign(:token, "same-token")
      |> Socket.assign(:configured_origin_id, nil)

    prior_generation = socket.assigns.timing_context.generation

    assert {:noreply, reactivated} =
             SessionClient.handle_cast(
               {:activate_origin, "https://example.com", "same-token"},
               socket
             )

    assert reactivated.assigns.subscribers["mobile:user:me"] == MapSet.new([self()])
    assert reactivated.assigns.timing_context.cycle == :reconnect
    refute reactivated.assigns.timing_context.generation == prior_generation
  end

  test "explicitly activating the current origin preserves watchers and requests fresh connection" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "http://127.0.0.1:1")
      |> Socket.assign(:token, "same-token")

    prior_generation = socket.assigns.timing_context.generation

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:activate_origin, "http://127.0.0.1:1", "same-token"},
               socket
             )

    assert socket.assigns.subscribers["mobile:user:me"] == MapSet.new([self()])
    assert socket.assigns.url == "http://127.0.0.1:1"
    assert socket.assigns.token == "same-token"
    assert socket.assigns.connecting?
    assert socket.assigns.timing_context.cycle == :reconnect
    refute socket.assigns.timing_context.generation == prior_generation
    reconnect_generation = socket.assigns.timing_context.generation

    assert {:noreply, reactivated} =
             SessionClient.handle_cast(
               {:activate_origin, "http://127.0.0.1:1", "same-token"},
               socket
             )

    # The first asynchronous open is still pending, so a second activation is
    # serialized instead of creating a concurrent Slipstream connection.
    assert reactivated.assigns.timing_context.generation == reconnect_generation
    assert reactivated.assigns.pending_configuration.force_reconnect?
  end

  test "intentional reconfigure waits for the closing transport before rotating generation" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_feed_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "https://example.com")
      |> Socket.assign(:token, "old-token")
      |> Socket.assign(:configured_origin_id, "origin-1")
      |> Socket.assign(:connecting?, false)
      |> Map.put(:channel_pid, self())

    closing_generation = socket.assigns.timing_context.generation

    assert {:noreply, queued} =
             SessionClient.handle_cast(
               {:activate_origin, "https://example.com", "new-token", "origin-1"},
               socket
             )

    assert queued.assigns.timing_context.generation == closing_generation
    assert queued.assigns.pending_configuration.token == "new-token"
    assert queued.assigns.connecting?

    assert_receive {:__slipstream_command__, %Slipstream.Commands.CloseConnection{}}
    refute_receive {:feed_stage, _measurements, %{stage: :connect_requested}}

    closed =
      Slipstream.Socket.apply_event(
        queued,
        %Slipstream.Events.ChannelClosed{reason: :client_disconnect_requested}
      )

    assert {:ok, reconnecting} =
             SessionClient.handle_disconnect(:client_disconnect_requested, closed)

    reconnect_generation = reconnecting.assigns.timing_context.generation
    refute reconnect_generation == closing_generation
    assert reconnecting.assigns.timing_context.cycle == :reconnect
    assert reconnecting.assigns.pending_configuration == nil
    assert reconnecting.assigns.connecting?
    assert reconnecting.assigns.url == "https://example.com"
    assert reconnecting.assigns.token == "new-token"

    assert_receive {:feed_stage, _measurements,
                    %{
                      stage: :disconnected,
                      connection_generation: ^closing_generation
                    }}

    assert_receive {:feed_stage, _measurements,
                    %{
                      stage: :connect_requested,
                      connection_generation: ^reconnect_generation
                    }}

    refute_receive {:feed_stage, _measurements, %{stage: :connect_requested}}

    query = URI.decode_query(reconnecting.channel_config.uri.query)
    assert query["connection_generation"] == reconnect_generation
    assert query["connection_cycle"] == "reconnect"
  end

  test "a queued origin switch makes old-origin snapshots unreadable before close" do
    push_sink = start_push_sink(self())
    old_snapshot = %{"version" => 7, "cards" => [%{"id" => "old-origin-card"}]}

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "https://old.example")
      |> Socket.assign(:token, "old-token")
      |> Socket.assign(:configured_origin_id, "origin-old")
      |> Socket.assign(:topic_snapshots, %{"mobile:user:me" => old_snapshot})
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)

    assert {:noreply, queued} =
             SessionClient.handle_cast(
               {:activate_origin, "https://new.example", "new-token", "origin-new"},
               socket
             )

    assert queued.assigns.subscribers == %{}
    assert queued.assigns.topic_snapshots == %{}
    assert queued.assigns.pending_configuration.origin_changed?
    assert queued.assigns.pending_configuration.origin_state_cleared?
    assert_receive {:mobile_cards_status, :disconnected}
    assert_receive {:connection_command, %Slipstream.Commands.CloseConnection{}}

    assert {:noreply, waiting} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, queued)

    assert {:noreply, waiting} =
             SessionClient.handle_cast({:watch, "old-workspace", self()}, waiting)

    assert waiting.assigns.subscribers["mobile:user:me"] == MapSet.new([self()])
    assert waiting.assigns.subscribers["session:old-workspace"] == MapSet.new([self()])
    refute_receive {:mobile_cards_snapshot, ^old_snapshot}
    refute_receive {:mobile_cards_status, :joined}
    refute_receive {:__slipstream_command__, %Slipstream.Commands.JoinTopic{}}

    assert {:noreply, waiting} =
             SessionClient.handle_cast(
               {:card_action, "old-card", "approve", nil, "origin-old"},
               waiting
             )

    assert {:noreply, ^waiting} =
             SessionClient.handle_cast({:mobile_observation, %{"event" => "resume"}}, waiting)

    assert {:noreply, ^waiting} =
             SessionClient.handle_cast({:attention_viewed, %{"marker" => 9}}, waiting)

    assert {:noreply, ^waiting} =
             SessionClient.handle_cast(
               {:register_push, "old-workspace", "push-token", "ios"},
               waiting
             )

    assert {:noreply, ^waiting} =
             SessionClient.handle_cast({:register_user_push, "push-token", "ios"}, waiting)

    assert_receive {:card_action_result, "old-card", {:error, :not_connected}}
    refute_receive {:push_message, %Slipstream.Commands.PushMessage{}}

    assert {:ok, waiting} =
             SessionClient.handle_message(
               "mobile:user:me",
               "cards_snapshot",
               mobile_snapshot(waiting, 8),
               waiting
             )

    assert {:ok, waiting} =
             SessionClient.handle_message(
               "session:old-workspace",
               "snapshot",
               %{"private" => "old-origin-state"},
               waiting
             )

    assert waiting.assigns.topic_snapshots == %{}
    refute_receive {:mobile_cards_snapshot, _payload}
    refute_receive {:session_snapshot, "old-workspace", _payload}
  end

  test "latest configuration replaces a pending origin switch even when returning to current" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "https://a.example")
      |> Socket.assign(:token, "token-a")
      |> Socket.assign(:configured_origin_id, "origin-a")
      |> Map.put(:channel_pid, self())

    assert {:noreply, pending_b} =
             SessionClient.handle_cast(
               {:activate_origin, "https://b.example", "token-b", "origin-b"},
               socket
             )

    assert pending_b.assigns.pending_configuration.origin_id == "origin-b"
    assert_receive {:__slipstream_command__, %Slipstream.Commands.CloseConnection{}}

    assert {:noreply, pending_b} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, pending_b)

    assert {:noreply, pending_b} =
             SessionClient.handle_cast({:watch, "workspace-b", self()}, pending_b)

    assert Map.has_key?(pending_b.assigns.subscribers, "mobile:user:me")
    assert Map.has_key?(pending_b.assigns.subscribers, "session:workspace-b")

    assert {:noreply, pending_a} =
             SessionClient.handle_cast(
               {:configure, "https://a.example", "token-a", "origin-a"},
               pending_b
             )

    assert pending_a.assigns.pending_configuration.origin_id == "origin-a"
    assert pending_a.assigns.pending_configuration.url == "https://a.example"
    assert pending_a.assigns.pending_configuration.force_reconnect?
    refute pending_a.assigns.pending_configuration.origin_changed?
    assert pending_a.assigns.pending_configuration.origin_state_cleared?
    assert pending_a.assigns.subscribers == %{}
    refute_receive {:__slipstream_command__, %Slipstream.Commands.CloseConnection{}}

    closed =
      Slipstream.Socket.apply_event(
        pending_a,
        %Slipstream.Events.ChannelClosed{reason: :client_disconnect_requested}
      )

    assert {:ok, reconnecting_a} =
             SessionClient.handle_disconnect(:client_disconnect_requested, closed)

    assert reconnecting_a.assigns.pending_configuration == nil
    assert reconnecting_a.assigns.configured_origin_id == "origin-a"
    assert reconnecting_a.assigns.url == "https://a.example"
    assert reconnecting_a.assigns.token == "token-a"
    assert reconnecting_a.assigns.timing_context.cycle == :reconnect

    query = URI.decode_query(reconnecting_a.channel_config.uri.query)
    assert query["connection_cycle"] == "reconnect"
  end

  test "a card action reply notifies subscribers with the result" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:card_action_refs, %{"ref-9" => %{card_id: "needs_review:ws-1:run-1"}})

    reply = {:ok, %{"status" => "accepted", "idempotent" => false}}
    assert {:ok, socket} = SessionClient.handle_reply("ref-9", reply, socket)

    assert socket.assigns.card_action_refs == %{}

    assert_receive {:card_action_result, "needs_review:ws-1:run-1",
                    {:ok, %{"status" => "accepted"}}}
  end

  test "a card action error reply surfaces the reason string" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:card_action_refs, %{"ref-9" => %{card_id: "c1"}})

    assert {:ok, _socket} =
             SessionClient.handle_reply("ref-9", {:error, %{"reason" => "note_required"}}, socket)

    assert_receive {:card_action_result, "c1", {:error, "note_required"}}
  end

  test "a joined mobile topic forwards the exact attention cursor payload" do
    push_sink = start_push_sink(self())

    params = %{
      "origin_id" => "origin-1",
      "card_id" => "in_progress:ws-1:run-1",
      "attention_key" => "ws-1:session:run-1",
      "through_marker" => 42
    }

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)

    assert {:noreply, ^socket} = SessionClient.handle_cast({:attention_viewed, params}, socket)
    assert_receive {:push_message, %Slipstream.Commands.PushMessage{} = command}

    assert Map.take(Map.from_struct(command), [:topic, :event, :payload]) == %{
             topic: "mobile:user:me",
             event: "attention_viewed",
             payload: params
           }
  end

  test "malformed join establishes no baseline and a later valid push recovers" do
    socket = socket_with_subscriber("mobile:user:me", self())
    malformed = mobile_snapshot(socket, "4", [%{"id" => "must-not-leak"}])

    assert {:ok, socket} = SessionClient.handle_join("mobile:user:me", malformed, socket)
    assert socket.assigns.accepted_mobile_snapshot_version == nil
    assert socket.assigns.topic_snapshots == %{}
    refute_receive {:mobile_cards_snapshot, _payload}
    refute_receive {:mobile_cards_status, :joined}

    valid = mobile_snapshot(socket, 4, [%{"id" => "accepted"}])

    assert {:ok, socket} =
             SessionClient.handle_message("mobile:user:me", "cards_snapshot", valid, socket)

    assert socket.assigns.accepted_mobile_snapshot_version == 4
    assert socket.assigns.topic_snapshots["mobile:user:me"]["cards"] == valid["cards"]
    assert_receive {:mobile_cards_snapshot, received}
    assert received["cards"] == valid["cards"]
    assert_receive {:mobile_cards_status, :joined}
  end

  test "authenticated snapshot atomically upgrades the configured legacy origin" do
    url = "https://casein.test"
    legacy_origin_id = OriginIdentity.legacy_id(url)
    SessionConfig.put_pairing(url, "token")

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, url)
      |> Socket.assign(:token, "token")
      |> Socket.assign(:configured_origin_id, legacy_origin_id)
      |> Socket.assign(:expected_mobile_snapshot_origin_id, legacy_origin_id)

    assert {:ok, upgraded} =
             SessionClient.handle_join("mobile:user:me", mobile_snapshot(socket, 1), socket)

    assert upgraded.assigns.configured_origin_id == "origin-1"
    assert upgraded.assigns.expected_mobile_snapshot_origin_id == "origin-1"
    assert upgraded.assigns.accepted_mobile_snapshot_origin_id == "origin-1"
    assert {:ok, %{origin_id: "origin-1"}} = SessionConfig.connection()
  end

  test "stable origin mismatch remains rejected without changing configured identity" do
    SessionConfig.put_pairing(%{
      origin_id: "origin-old",
      display_name: "Old",
      url: "https://casein.test",
      token: "token"
    })

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:configured_origin_id, "origin-old")
      |> Socket.assign(:expected_mobile_snapshot_origin_id, nil)

    assert {:ok, rejected} =
             SessionClient.handle_join("mobile:user:me", mobile_snapshot(socket, 1), socket)

    assert rejected.assigns.configured_origin_id == "origin-old"
    assert rejected.assigns.accepted_mobile_snapshot_origin_id == nil
    assert rejected.assigns.topic_snapshots == %{}
    assert {:ok, %{origin_id: "origin-old"}} = SessionConfig.connection()
    refute_receive {:mobile_cards_snapshot, _payload}
  end

  test "stale socket snapshot cannot relabel a newly activated legacy profile" do
    active_url = "https://active-now.test"
    stale_url = "https://stale-socket.test"
    active_legacy_id = OriginIdentity.legacy_id(active_url)
    stale_legacy_id = OriginIdentity.legacy_id(stale_url)
    SessionConfig.put_pairing(active_url, "active-token")

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, stale_url)
      |> Socket.assign(:token, "stale-token")
      |> Socket.assign(:configured_origin_id, stale_legacy_id)
      |> Socket.assign(:expected_mobile_snapshot_origin_id, nil)

    assert {:ok, rejected} =
             SessionClient.handle_join("mobile:user:me", mobile_snapshot(socket, 1), socket)

    assert rejected.assigns.configured_origin_id == stale_legacy_id
    assert rejected.assigns.accepted_mobile_snapshot_origin_id == nil
    assert {:ok, %{origin_id: ^active_legacy_id, url: ^active_url}} = SessionConfig.connection()

    assert [%{origin_id: ^active_legacy_id, active?: true}] = SessionConfig.host_profiles()
    refute_receive {:mobile_cards_snapshot, _payload}
  end

  test "legacy reconciliation rebinds a pending terminal before exactly one create" do
    push_sink = start_push_sink(self())
    url = "https://casein.test"
    legacy_origin_id = OriginIdentity.legacy_id(url)
    SessionConfig.put_pairing(url, "token")

    terminal = %{
      subscriber: self(),
      origin_id: legacy_origin_id,
      workspace_id: "ws-1",
      status: :connecting,
      lease: nil,
      channel_topic: nil,
      child_grant: nil,
      grant_expires_at: nil,
      connection_generation: nil,
      stream: nil,
      control_ref: nil,
      retry_attempt: 0,
      retry_token: nil,
      retry_timer: nil
    }

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Socket.assign(:url, url)
      |> Socket.assign(:token, "token")
      |> Socket.assign(:configured_origin_id, legacy_origin_id)
      |> Socket.assign(:expected_mobile_snapshot_origin_id, legacy_origin_id)
      |> Socket.assign(:mobile_terminal, terminal)
      |> Map.put(:channel_pid, push_sink)

    assert {:ok, creating} =
             SessionClient.handle_join("mobile:user:me", mobile_snapshot(socket, 1), socket)

    assert creating.assigns.configured_origin_id == "origin-1"
    assert creating.assigns.mobile_terminal.origin_id == "origin-1"
    assert creating.assigns.mobile_terminal.status == :create

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_create",
                      payload: %{origin_id: "origin-1", workspace_id: "ws-1"}
                    }}

    refute_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_create"}}
  end

  test "legacy reconciliation purges an already in-flight terminal without retargeting it" do
    push_sink = start_push_sink(self())
    url = "https://casein.test"
    legacy_origin_id = OriginIdentity.legacy_id(url)
    SessionConfig.put_pairing(url, "token")

    terminal =
      self()
      |> terminal_state()
      |> Map.put(:origin_id, legacy_origin_id)
      |> Map.put(:lease, nil)
      |> Map.put(:channel_topic, nil)
      |> Map.put(:stream, nil)
      |> Map.put(:control_ref, "legacy-create-ref")
      |> Map.put(:status, :create)

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, url)
      |> Socket.assign(:token, "token")
      |> Socket.assign(:configured_origin_id, legacy_origin_id)
      |> Socket.assign(:expected_mobile_snapshot_origin_id, legacy_origin_id)
      |> Socket.assign(:terminal_control_refs, %{
        "legacy-create-ref" => %{
          operation: :create,
          origin_id: legacy_origin_id,
          workspace_id: "ws-1"
        }
      })
      |> Socket.assign(:mobile_terminal, terminal)
      |> Map.put(:channel_pid, push_sink)

    assert {:ok, upgraded} =
             SessionClient.handle_join("mobile:user:me", mobile_snapshot(socket, 1), socket)

    assert upgraded.assigns.configured_origin_id == "origin-1"
    assert upgraded.assigns.mobile_terminal == nil
    refute_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_create"}}
  end

  test "negative, string, float, nil, and missing versions fail closed" do
    socket = socket_with_subscriber("mobile:user:me", self())

    invalid_payloads =
      [-1, "1", 1.0, nil]
      |> Enum.map(&mobile_snapshot(socket, &1, [%{"id" => "must-not-leak"}]))
      |> Kernel.++([Map.delete(mobile_snapshot(socket, 1), "version")])

    socket =
      Enum.reduce(invalid_payloads, socket, fn payload, socket ->
        assert {:ok, socket} =
                 SessionClient.handle_message(
                   "mobile:user:me",
                   "cards_snapshot",
                   payload,
                   socket
                 )

        socket
      end)

    assert socket.assigns.accepted_mobile_snapshot_version == nil
    assert socket.assigns.topic_snapshots == %{}
    refute_receive {:mobile_cards_snapshot, _payload}
    refute_receive {:mobile_cards_status, :joined}
  end

  test "boolean versions never establish or mutate the mobile snapshot baseline" do
    topic = "mobile:user:me"
    socket = socket_with_subscriber(topic, self())

    socket =
      Enum.reduce([true, false], socket, fn version, socket ->
        invalid = mobile_snapshot(socket, version, [%{"id" => "must-not-leak"}])

        assert {:ok, rejected} = SessionClient.handle_join(topic, invalid, socket)
        assert rejected.assigns.accepted_mobile_snapshot_version == nil
        assert rejected.assigns.accepted_mobile_snapshot_origin_id == nil
        assert rejected.assigns.topic_snapshots == %{}
        refute_receive {:mobile_cards_snapshot, _payload}
        refute_receive {:mobile_cards_status, :joined}
        rejected
      end)

    baseline = mobile_snapshot(socket, 6, [%{"id" => "accepted"}])
    assert {:ok, socket} = SessionClient.handle_join(topic, baseline, socket)
    assert socket.assigns.topic_snapshots[topic]["cards"] == baseline["cards"]
    assert_receive {:mobile_cards_snapshot, received}
    assert received["cards"] == baseline["cards"]
    assert_receive {:mobile_cards_status, :joined}

    accepted_cache = socket.assigns.topic_snapshots

    Enum.reduce([true, false], socket, fn version, socket ->
      invalid = mobile_snapshot(socket, version, [%{"id" => "must-not-replace"}])

      assert {:ok, rejected} = SessionClient.handle_join(topic, invalid, socket)
      assert rejected.assigns.accepted_mobile_snapshot_version == 6
      assert rejected.assigns.accepted_mobile_snapshot_origin_id == "origin-1"
      assert rejected.assigns.topic_snapshots == accepted_cache
      refute_receive {:mobile_cards_snapshot, _payload}
      refute_receive {:mobile_cards_status, :joined}
      rejected
    end)
  end

  test "lower versions preserve the accepted cache while equal versions refresh metadata" do
    socket = socket_with_subscriber("mobile:user:me", self())
    baseline = mobile_snapshot(socket, 8, [], %{"live_work" => %{"status" => "hydrating"}})

    assert {:ok, socket} = SessionClient.handle_join("mobile:user:me", baseline, socket)
    assert_receive {:mobile_cards_snapshot, _payload}
    assert_receive {:mobile_cards_status, :joined}

    lower = mobile_snapshot(socket, 7, [%{"id" => "must-not-leak"}])

    assert {:ok, rejected} =
             SessionClient.handle_message("mobile:user:me", "cards_snapshot", lower, socket)

    assert rejected.assigns.accepted_mobile_snapshot_version == 8

    assert rejected.assigns.topic_snapshots["mobile:user:me"]["live_work"]["status"] ==
             "hydrating"

    refute_receive {:mobile_cards_snapshot, _payload}

    equal =
      mobile_snapshot(rejected, 8, [], %{"live_work" => %{"status" => "authoritative"}})

    assert {:ok, refreshed} =
             SessionClient.handle_message("mobile:user:me", "cards_snapshot", equal, rejected)

    assert refreshed.assigns.accepted_mobile_snapshot_version == 8

    assert refreshed.assigns.topic_snapshots["mobile:user:me"]["live_work"]["status"] ==
             "authoritative"

    assert_receive {:mobile_cards_snapshot, received}
    assert received["live_work"]["status"] == "authoritative"
  end

  test "disconnect rejects its window and reconnect accepts a lower new baseline" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:test_mode?, true)

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:configure, "http://127.0.0.1:1", "token"},
               socket
             )

    assert {:ok, socket} =
             SessionClient.handle_join("mobile:user:me", mobile_snapshot(socket, 9), socket)

    assert_receive {:mobile_cards_snapshot, _payload}
    assert_receive {:mobile_cards_status, :joined}

    old_context = socket.assigns.timing_context
    assert {:ok, disconnected} = SessionClient.handle_disconnect(:closed, socket)
    assert_receive {:mobile_cards_status, :disconnected}

    during_disconnect = mobile_snapshot(disconnected, 10)

    assert {:ok, disconnected} =
             SessionClient.handle_message(
               "mobile:user:me",
               "cards_snapshot",
               during_disconnect,
               disconnected
             )

    assert disconnected.assigns.topic_snapshots == %{}
    refute_receive {:mobile_cards_snapshot, _payload}

    assert {:ok, reconnected} = SessionClient.handle_connect(disconnected)

    old_generation =
      reconnected
      |> mobile_snapshot(99)
      |> Map.put("connection_generation", old_context.generation)
      |> Map.put("connection_cycle", Atom.to_string(old_context.cycle))

    assert {:ok, reconnected} =
             SessionClient.handle_message(
               "mobile:user:me",
               "cards_snapshot",
               old_generation,
               reconnected
             )

    assert reconnected.assigns.accepted_mobile_snapshot_version == nil
    refute_receive {:mobile_cards_snapshot, _payload}

    new_baseline = mobile_snapshot(reconnected, 1)

    assert {:ok, recovered} =
             SessionClient.handle_message(
               "mobile:user:me",
               "cards_snapshot",
               new_baseline,
               reconnected
             )

    assert recovered.assigns.accepted_mobile_snapshot_version == 1
    assert_receive {:mobile_cards_snapshot, _payload}
    assert_receive {:mobile_cards_status, :joined}
  end

  test "a stale handle_join reply cannot establish or mutate the reconnect baseline" do
    topic = "mobile:user:me"

    socket =
      socket_with_subscriber(topic, self())
      |> Socket.assign(:test_mode?, true)

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:configure, "http://127.0.0.1:1", "token"},
               socket
             )

    old_context = socket.assigns.timing_context

    assert {:ok, reconnecting} = SessionClient.handle_disconnect(:closed, socket)
    assert_receive {:mobile_cards_status, :disconnected}
    assert {:ok, reconnected} = SessionClient.handle_connect(reconnecting)

    new_context = reconnected.assigns.timing_context
    refute new_context.generation == old_context.generation
    assert new_context.cycle == :reconnect

    # Keep the new generation's origin and cycle valid so the old generation
    # is the only fence responsible for rejecting this delayed join reply.
    stale_reply =
      reconnected
      |> mobile_snapshot(99, [%{"id" => "stale-old-generation"}])
      |> Map.put("connection_generation", old_context.generation)

    assert stale_reply["connection_generation"] == old_context.generation
    assert stale_reply["connection_cycle"] == Atom.to_string(new_context.cycle)
    assert stale_reply["origin"]["id"] == "origin-1"

    assert {:ok, reconnected} = SessionClient.handle_join(topic, stale_reply, reconnected)
    assert reconnected.assigns.accepted_mobile_snapshot_version == nil
    assert reconnected.assigns.accepted_mobile_snapshot_origin_id == nil
    assert reconnected.assigns.topic_snapshots == %{}
    refute_receive {:mobile_cards_snapshot, _payload}
    refute_receive {:mobile_cards_status, :joined}

    current_reply = mobile_snapshot(reconnected, 1, [%{"id" => "current-generation"}])
    assert current_reply["connection_generation"] == new_context.generation
    assert current_reply["connection_cycle"] == Atom.to_string(new_context.cycle)
    assert current_reply["origin"] == stale_reply["origin"]

    assert {:ok, accepted} = SessionClient.handle_join(topic, current_reply, reconnected)
    assert accepted.assigns.accepted_mobile_snapshot_version == 1
    assert accepted.assigns.accepted_mobile_snapshot_origin_id == "origin-1"
    assert accepted.assigns.topic_snapshots[topic]["cards"] == current_reply["cards"]
    assert_receive {:mobile_cards_snapshot, received}
    assert received["cards"] == current_reply["cards"]
    assert_receive {:mobile_cards_status, :joined}

    accepted_cache = accepted.assigns.topic_snapshots

    assert {:ok, rejected} = SessionClient.handle_join(topic, stale_reply, accepted)
    assert rejected.assigns.accepted_mobile_snapshot_version == 1
    assert rejected.assigns.accepted_mobile_snapshot_origin_id == "origin-1"
    assert rejected.assigns.topic_snapshots == accepted_cache
    refute_receive {:mobile_cards_snapshot, _payload}
    refute_receive {:mobile_cards_status, :joined}
  end

  test "mismatched connection cycle and origin are rejected before cache or notify" do
    socket = socket_with_subscriber("mobile:user:me", self())

    assert {:ok, socket} =
             SessionClient.handle_join("mobile:user:me", mobile_snapshot(socket, 2), socket)

    assert_receive {:mobile_cards_snapshot, _payload}
    assert_receive {:mobile_cards_status, :joined}

    wrong_cycle =
      socket
      |> mobile_snapshot(3)
      |> Map.put("connection_cycle", "origin_switch")

    assert {:ok, socket} =
             SessionClient.handle_message(
               "mobile:user:me",
               "cards_snapshot",
               wrong_cycle,
               socket
             )

    wrong_origin =
      socket
      |> mobile_snapshot(3)
      |> Map.put("origin", %{"id" => "origin-2", "display_name" => "Other"})

    assert {:ok, socket} =
             SessionClient.handle_message(
               "mobile:user:me",
               "cards_snapshot",
               wrong_origin,
               socket
             )

    assert socket.assigns.accepted_mobile_snapshot_version == 2
    assert socket.assigns.topic_snapshots["mobile:user:me"]["version"] == 2
    refute_receive {:mobile_cards_snapshot, _payload}
  end

  test "render-ready acknowledgement emits once per current generation and rejects stale ones" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_feed_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:test_mode?, true)

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:configure, "http://127.0.0.1:1", "token"},
               socket
             )

    generation = socket.assigns.timing_context.generation

    assert {:noreply, socket} =
             SessionClient.handle_cast({:cards_render_ready, generation, 3}, socket)

    assert socket.assigns.render_ready_generation == generation

    assert_receive {:feed_stage, %{card_count: 3},
                    %{
                      stage: :first_cards_render_ready,
                      connection_generation: ^generation
                    }}

    assert {:noreply, socket} =
             SessionClient.handle_cast({:cards_render_ready, generation, 4}, socket)

    refute_receive {:feed_stage, _measurements, %{stage: :first_cards_render_ready}}

    assert {:ok, reconnecting} = SessionClient.handle_disconnect(:closed, socket)
    next_generation = reconnecting.assigns.timing_context.generation
    refute next_generation == generation
    assert reconnecting.assigns.render_ready_generation == nil

    assert {:noreply, reconnecting} =
             SessionClient.handle_cast({:cards_render_ready, generation, 5}, reconnecting)

    assert reconnecting.assigns.render_ready_generation == nil
    refute_receive {:feed_stage, _measurements, %{stage: :first_cards_render_ready}}

    assert {:noreply, reconnecting} =
             SessionClient.handle_cast(
               {:cards_render_ready, next_generation, 6},
               reconnecting
             )

    assert reconnecting.assigns.render_ready_generation == next_generation

    assert_receive {:feed_stage, %{card_count: 6},
                    %{
                      stage: :first_cards_render_ready,
                      connection_generation: ^next_generation
                    }}
  end

  test "an unavailable origin store without an expected origin fails closed" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:expected_mobile_snapshot_origin_id, nil)

    assert {:ok, socket} =
             SessionClient.handle_join("mobile:user:me", mobile_snapshot(socket, 1), socket)

    assert socket.assigns.accepted_mobile_snapshot_version == nil
    assert socket.assigns.accepted_mobile_snapshot_origin_id == nil
    assert socket.assigns.topic_snapshots == %{}
    refute_receive {:mobile_cards_snapshot, _payload}
    refute_receive {:mobile_cards_status, :joined}
  end

  test "an unrelated reply ref is ignored" do
    socket = socket_with_subscriber("mobile:user:me", self())
    assert {:ok, _socket} = SessionClient.handle_reply("unknown-ref", :ok, socket)
    refute_receive {:card_action_result, _card_id, _result}
  end

  test "terminal grant stays out of snapshots and only an accepted baseline advances freshness" do
    push_sink = start_push_sink(self())

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)

    assert {:noreply, socket} =
             SessionClient.handle_cast({:watch_terminal, "ws-1", self()}, socket)

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      topic: "mobile:user:me",
                      event: "terminal_create",
                      payload: %{workspace_id: "ws-1", request_id: request_id}
                    }}

    assert {:ok, _} = Ecto.UUID.cast(request_id)
    generation = socket.assigns.timing_context.generation

    assert {:ok, socket} =
             SessionClient.handle_reply(
               "push-ref",
               {:ok, terminal_control_reply("created")},
               socket
             )

    assert_receive {:connection_command,
                    %Slipstream.Commands.JoinTopic{
                      topic: "mobile_terminal:lease-1",
                      payload: %{
                        "child_grant" => "one-time-secret",
                        "connection_generation" => ^generation
                      }
                    }}

    assert socket.assigns.topic_snapshots == %{}
    assert socket.assigns.terminal_baseline_generation == 0
    assert socket.assigns.mobile_terminal.child_grant == nil
    assert socket.assigns.mobile_terminal.diagnostic.stage == :child_join_requested
    assert socket.assigns.mobile_terminal.diagnostic.counts.status_delivered == 2
    assert socket.assigns.mobile_terminal.diagnostic.counts.control_reply_accepted == 1
    assert socket.assigns.mobile_terminal.diagnostic.counts.child_join_requested == 1

    assert socket.joins["mobile_terminal:lease-1"].params == %{
             "connection_generation" => generation
           }

    refute inspect(socket) =~ "one-time-secret"

    baseline = terminal_frame("terminal_baseline", "hello", generation, 0)

    assert {:ok, socket} =
             SessionClient.handle_join("mobile_terminal:lease-1", baseline, socket)

    assert socket.assigns.terminal_baseline_generation == 1
    assert socket.assigns.mobile_terminal.child_grant == nil
    assert socket.assigns.topic_snapshots == %{}

    assert_receive {:mobile_terminal_baseline,
                    %{
                      fresh_baseline_generation: 1,
                      workspace_id: "ws-1",
                      terminal_diagnostic: diagnostic
                    }, "hello"}

    assert diagnostic.counts.child_join_reply_received == 1
    assert diagnostic.counts.baseline_accepted == 1

    assert {:ok, duplicate} =
             SessionClient.handle_message(
               "mobile_terminal:lease-1",
               "terminal_output",
               baseline,
               socket
             )

    assert duplicate.assigns.terminal_baseline_generation == 1
    refute_receive {:mobile_terminal_baseline, _, _}
  end

  test "repeated watch for the same selected terminal emits terminal_create exactly once" do
    push_sink = start_push_sink(self())

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Socket.assign(:configured_origin_id, "origin-1")
      |> Map.put(:channel_pid, push_sink)

    assert {:noreply, creating} =
             SessionClient.handle_cast(
               {:watch_terminal, "origin-1", "ws-1", self()},
               socket
             )

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_create",
                      payload: %{workspace_id: "ws-1"}
                    }}

    assert {:noreply, still_creating} =
             SessionClient.handle_cast({:watch_terminal, "ws-1", self()}, creating)

    assert still_creating.assigns.mobile_terminal.control_ref ==
             creating.assigns.mobile_terminal.control_ref

    refute_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_create"}}
  end

  test "rapid remount transfers an in-flight terminal create to the new subscriber exactly once" do
    push_sink = start_push_sink(self())

    new_subscriber =
      start_supervised!(%{
        id: make_ref(),
        start: {Task, :start_link, [fn -> receive do: (:stop -> :ok) end]}
      })

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Socket.assign(:configured_origin_id, "origin-1")
      |> Map.put(:channel_pid, push_sink)

    assert {:noreply, creating} =
             SessionClient.handle_cast(
               {:watch_terminal, "origin-1", "ws-1", self()},
               socket
             )

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_create",
                      payload: %{workspace_id: "ws-1"}
                    }}

    create_ref = creating.assigns.mobile_terminal.control_ref

    assert {:noreply, remounted} =
             SessionClient.handle_cast(
               {:watch_terminal, "origin-1", "ws-1", new_subscriber},
               creating
             )

    assert remounted.assigns.mobile_terminal.subscriber == new_subscriber
    assert remounted.assigns.mobile_terminal.control_ref == create_ref
    assert remounted.assigns.mobile_terminal.status == :create
    assert remounted.assigns.subscribers["mobile:user:me"] == MapSet.new([new_subscriber])
    refute Map.has_key?(remounted.assigns.subscriber_monitors, self())
    assert is_reference(remounted.assigns.subscriber_monitors[new_subscriber])
    refute_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_create"}}
    refute_receive {:connection_command, %Slipstream.Commands.LeaveTopic{}}
    refute_receive {:connection_command, %Slipstream.Commands.JoinTopic{topic: "mobile:user:me"}}

    assert {:ok, resolved} =
             SessionClient.handle_reply(
               create_ref,
               {:ok, terminal_control_reply("created")},
               remounted
             )

    assert resolved.assigns.mobile_terminal.subscriber == new_subscriber
    assert resolved.assigns.mobile_terminal.lease.workspace_id == "ws-1"
  end

  test "terminal create fails closed when expected origin changed before the watch cast" do
    push_sink = start_push_sink(self())

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Socket.assign(:configured_origin_id, "origin-new")
      |> Map.put(:channel_pid, push_sink)

    assert {:noreply, rejected} =
             SessionClient.handle_cast(
               {:watch_terminal, "origin-old", "ws-1", self()},
               socket
             )

    assert rejected.assigns.mobile_terminal.status == {:error, :inactive_origin}
    refute_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_create"}}
  end

  test "terminal create reply revalidates stored origin and workspace before binding a lease" do
    push_sink = start_push_sink(self())

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Socket.assign(:configured_origin_id, "origin-1")
      |> Map.put(:channel_pid, push_sink)

    assert {:noreply, creating} =
             SessionClient.handle_cast(
               {:watch_terminal, "origin-1", "ws-1", self()},
               socket
             )

    assert_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_create"}}
    ref = creating.assigns.mobile_terminal.control_ref

    switched = Socket.assign(creating, :configured_origin_id, "origin-other")

    assert {:ok, rejected_origin} =
             SessionClient.handle_reply(
               ref,
               {:ok, terminal_control_reply("created")},
               switched
             )

    assert rejected_origin.assigns.mobile_terminal.lease == nil
    assert rejected_origin.assigns.mobile_terminal.stream == nil
    assert rejected_origin.assigns.mobile_terminal.status == {:error, :identity_mismatch}

    wrong_workspace_reply =
      put_in(terminal_control_reply("created"), ["lease", "workspace_id"], "ws-other")

    assert {:ok, rejected_workspace} =
             SessionClient.handle_reply(ref, {:ok, wrong_workspace_reply}, creating)

    assert rejected_workspace.assigns.mobile_terminal.lease == nil
    assert rejected_workspace.assigns.mobile_terminal.stream == nil
    assert rejected_workspace.assigns.mobile_terminal.status == {:error, :identity_mismatch}
  end

  test "terminal background purges bytes and foreground refreshes the retained lease" do
    push_sink = start_push_sink(self())

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)
      |> Socket.assign(:mobile_terminal, terminal_state(self()))

    assert {:noreply, covered} = SessionClient.handle_cast(:terminal_background, socket)
    assert covered.assigns.mobile_terminal.status == :backgrounded
    assert covered.assigns.mobile_terminal.child_grant == nil
    assert covered.assigns.mobile_terminal.stream == nil

    assert {:noreply, refreshing} = SessionClient.handle_cast(:terminal_foreground, covered)

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_refresh",
                      payload: %{lease_id: "lease-1"}
                    }}

    assert refreshing.assigns.mobile_terminal.status == :refresh
  end

  test "terminal unwatch sends one exact delete request and purges local state" do
    push_sink = start_push_sink(self())

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)
      |> Socket.assign(:mobile_terminal, terminal_state(self()))

    assert {:noreply, closed} =
             SessionClient.handle_cast({:unwatch_terminal, self()}, socket)

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_delete",
                      payload: %{lease_id: "lease-1", request_id: request_id}
                    }}

    assert {:ok, _} = Ecto.UUID.cast(request_id)
    assert closed.assigns.mobile_terminal == nil
    tombstone = Map.fetch!(closed.assigns.terminal_delete_tombstones, {:url, nil})
    assert tombstone.request_id == request_id
    assert tombstone.lease_id == "lease-1"
    refute_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_delete"}}
  end

  test "a dropped delete is retried idempotently after reconnect and forgotten only on exact ack" do
    push_sink = start_push_sink(self())

    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)
      |> Socket.assign(:mobile_terminal, terminal_state(self()))

    assert {:noreply, closed} =
             SessionClient.handle_cast({:unwatch_terminal, self()}, socket)

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_delete",
                      payload: %{lease_id: "lease-1", request_id: request_id}
                    }}

    assert {:ok, disconnected} = SessionClient.handle_disconnect(:closed, closed)
    assert disconnected.assigns.terminal_delete_tombstones[{:url, nil}].ref == nil

    assert {:ok, reconnecting} =
             disconnected
             |> Map.put(:channel_pid, push_sink)
             |> SessionClient.handle_connect()

    assert_receive {:connection_command, %Slipstream.Commands.JoinTopic{topic: "mobile:user:me"}}

    reconnected =
      put_in(
        reconnecting,
        [Access.key(:joins), "mobile:user:me", Access.key(:status)],
        :joined
      )

    assert {:ok, retried} =
             SessionClient.handle_join(
               "mobile:user:me",
               mobile_snapshot(reconnected, 1),
               reconnected
             )

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_delete",
                      payload: %{lease_id: "lease-1", request_id: ^request_id}
                    }}

    wrong_ack =
      {:ok, %{"schema" => "mobile_terminal_v1", "status" => "deleted", "lease_id" => "other"}}

    assert {:ok, retained} = SessionClient.handle_reply("push-ref", wrong_ack, retried)
    assert retained.assigns.terminal_delete_tombstones[{:url, nil}].request_id == request_id
    assert retained.assigns.terminal_delete_tombstones[{:url, nil}].ref == nil

    assert {:ok, retried_again} =
             SessionClient.handle_join(
               "mobile:user:me",
               mobile_snapshot(retained, 1),
               retained
             )

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_delete",
                      payload: %{request_id: ^request_id}
                    }}

    exact_ack =
      {:ok, %{"schema" => "mobile_terminal_v1", "status" => "deleted", "lease_id" => "lease-1"}}

    assert {:ok, acknowledged} =
             SessionClient.handle_reply("push-ref", exact_ack, retried_again)

    assert acknowledged.assigns.terminal_delete_tombstones == %{}

    assert_receive {:connection_command, %Slipstream.Commands.LeaveTopic{topic: "mobile:user:me"}}

    assert {:noreply, watching_again} =
             SessionClient.handle_cast({:watch_terminal, "workspace-1", self()}, acknowledged)

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_create",
                      payload: %{workspace_id: "workspace-1"}
                    }}

    assert watching_again.assigns.mobile_terminal.status == :create
  end

  test "a pending delete is isolated by origin and retained while another origin creates" do
    push_sink = start_push_sink(self())

    old_origin_socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:configured_origin_id, "origin-old")
      |> Socket.assign(:url, "wss://old.example/socket/websocket")
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)
      |> Socket.assign(:mobile_terminal, terminal_state(self()))

    assert {:noreply, old_closed} =
             SessionClient.handle_cast({:unwatch_terminal, self()}, old_origin_socket)

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_delete",
                      payload: %{lease_id: "lease-1", request_id: old_request_id}
                    }}

    assert {:ok, old_disconnected} = SessionClient.handle_disconnect(:closed, old_closed)

    old_scope = {:origin, "origin-old"}

    assert old_disconnected.assigns.terminal_delete_tombstones[old_scope].request_id ==
             old_request_id

    assert old_disconnected.assigns.terminal_delete_tombstones[old_scope].ref == nil

    new_origin_socket =
      old_disconnected
      |> Socket.assign(:configured_origin_id, "origin-new")
      |> Socket.assign(:url, "wss://new.example/socket/websocket")
      |> Socket.assign(:transport_ready?, true)
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)

    assert {:noreply, watching_new} =
             SessionClient.handle_cast(
               {:watch_terminal, "workspace-new", self()},
               new_origin_socket
             )

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_create",
                      payload: %{workspace_id: "workspace-new"}
                    }}

    assert watching_new.assigns.mobile_terminal.status == :create
    assert watching_new.assigns.terminal_delete_tombstones[old_scope].request_id == old_request_id
    refute_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_delete"}}
  end

  test "terminal join rejection refreshes with backoff and accepts a fresh one-time grant baseline" do
    push_sink = start_push_sink(self())
    socket = terminal_stream_socket(push_sink, self())

    assert {:ok, rejected} =
             SessionClient.handle_join(
               "mobile_terminal:lease-1",
               {:error, %{"reason" => "stale_grant"}},
               socket
             )

    token = rejected.assigns.mobile_terminal.retry_token
    assert is_reference(token)
    assert rejected.assigns.mobile_terminal.retry_attempt == 1
    assert rejected.assigns.mobile_terminal.stream == nil
    assert rejected.assigns.mobile_terminal.diagnostic.stage == :baseline_rejected
    assert rejected.assigns.mobile_terminal.diagnostic.counts.child_join_reply_received == 1
    assert rejected.assigns.mobile_terminal.diagnostic.counts.baseline_rejected == 1

    assert {:noreply, refreshing} =
             SessionClient.handle_info({:terminal_refresh_retry, token}, rejected)

    assert_receive {:push_message,
                    %Slipstream.Commands.PushMessage{
                      event: "terminal_refresh",
                      payload: %{lease_id: "lease-1"}
                    }}

    assert {:ok, awaiting} =
             SessionClient.handle_reply(
               "push-ref",
               {:ok, terminal_control_reply("refreshed", "fresh-one-time-grant")},
               refreshing
             )

    assert_receive {:connection_command,
                    %Slipstream.Commands.JoinTopic{
                      payload: %{"child_grant" => "fresh-one-time-grant"}
                    }}

    assert awaiting.assigns.mobile_terminal.child_grant == nil
    assert awaiting.assigns.mobile_terminal.diagnostic.stage == :child_join_requested
    refute Map.has_key?(awaiting.assigns.mobile_terminal.diagnostic.counts, :baseline_rejected)
    refute inspect(awaiting) =~ "fresh-one-time-grant"
    generation = awaiting.assigns.timing_context.generation

    assert {:ok, live} =
             SessionClient.handle_join(
               "mobile_terminal:lease-1",
               terminal_frame("terminal_baseline", "fresh", generation, 0),
               awaiting
             )

    assert live.assigns.mobile_terminal.status == :live
    assert live.assigns.mobile_terminal.retry_attempt == 0
    assert_receive {:mobile_terminal_baseline, _, "fresh"}
  end

  test "terminal close retries are capped and payload event mismatches fail closed" do
    push_sink = start_push_sink(self())
    socket = terminal_stream_socket(push_sink, self())
    generation = socket.assigns.timing_context.generation
    mismatched = terminal_frame("terminal_cutoff", "", generation, 0)

    assert {:ok, rejected} =
             SessionClient.handle_message(
               "mobile_terminal:lease-1",
               "terminal_output",
               mismatched,
               socket
             )

    assert rejected.assigns.mobile_terminal.stream == nil
    assert rejected.assigns.mobile_terminal.retry_attempt == 1
    refute_receive {:mobile_terminal_output, _}

    opposite = terminal_stream_socket(push_sink, self())

    assert {:ok, opposite_rejected} =
             SessionClient.handle_message(
               "mobile_terminal:lease-1",
               "terminal_cutoff",
               terminal_frame("terminal_output", "must-not-render", generation, 0),
               opposite
             )

    assert opposite_rejected.assigns.mobile_terminal.stream == nil
    refute_receive {:mobile_terminal_output, _}

    malformed = terminal_stream_socket(push_sink, self())

    assert {:ok, malformed_rejected} =
             SessionClient.handle_message(
               "mobile_terminal:lease-1",
               "terminal_output",
               "not-a-payload",
               malformed
             )

    assert malformed_rejected.assigns.mobile_terminal.stream == nil
    refute_receive {:mobile_terminal_output, _}

    assert {:ok, coalesced} =
             SessionClient.handle_topic_close(
               "mobile_terminal:lease-1",
               {:error, %{"reason" => "stale_grant"}},
               rejected
             )

    assert coalesced.assigns.mobile_terminal.retry_token ==
             rejected.assigns.mobile_terminal.retry_token

    capped =
      Enum.reduce(1..3, coalesced, fn _index, current ->
        token = current.assigns.mobile_terminal.retry_token

        assert {:noreply, attempted} =
                 SessionClient.handle_info({:terminal_refresh_retry, token}, current)

        assert_receive {:push_message,
                        %Slipstream.Commands.PushMessage{event: "terminal_refresh"}}

        assert {:ok, next} =
                 SessionClient.handle_topic_close(
                   "mobile_terminal:lease-1",
                   {:error, %{"reason" => "stale_grant"}},
                   attempted
                 )

        next
      end)

    assert capped.assigns.mobile_terminal.retry_attempt == 3
    assert capped.assigns.mobile_terminal.retry_token == nil
  end

  test "eligible terminal topic close refreshes to a fresh authoritative baseline" do
    push_sink = start_push_sink(self())
    socket = terminal_stream_socket(push_sink, self())

    assert {:ok, closed} =
             SessionClient.handle_topic_close(
               "mobile_terminal:lease-1",
               {:error, %{"reason" => "grant_expired"}},
               socket
             )

    token = closed.assigns.mobile_terminal.retry_token
    assert is_reference(token)

    assert {:noreply, refreshing} =
             SessionClient.handle_info({:terminal_refresh_retry, token}, closed)

    assert_receive {:push_message, %Slipstream.Commands.PushMessage{event: "terminal_refresh"}}

    assert {:ok, awaiting} =
             SessionClient.handle_reply(
               "push-ref",
               {:ok, terminal_control_reply("refreshed", "close-recovery-grant")},
               refreshing
             )

    assert_receive {:connection_command,
                    %Slipstream.Commands.JoinTopic{
                      payload: %{"child_grant" => "close-recovery-grant"}
                    }}

    generation = awaiting.assigns.timing_context.generation

    assert {:ok, live} =
             SessionClient.handle_join(
               "mobile_terminal:lease-1",
               terminal_frame("terminal_baseline", "recovered", generation, 0),
               awaiting
             )

    assert live.assigns.mobile_terminal.status == :live
    assert live.assigns.mobile_terminal.retry_attempt == 0
    refute inspect(live) =~ "close-recovery-grant"
    assert_receive {:mobile_terminal_baseline, _, "recovered"}
  end

  defp socket_with_subscriber(topic, subscriber) do
    socket_with_subscribers(%{topic => MapSet.new([subscriber])})
  end

  defp socket_with_subscribers(subscribers) do
    timing_context = ConnectionTiming.new_context(:cold)

    Socket.new()
    |> Socket.assign(:subscribers, subscribers)
    |> Socket.assign(:subscriber_monitors, %{})
    |> Socket.assign(:topic_snapshots, %{})
    |> Socket.assign(:url, nil)
    |> Socket.assign(:token, nil)
    |> Socket.assign(:configured_origin_id, nil)
    |> Socket.assign(:connecting?, false)
    |> Socket.assign(:reconnect_generation_required?, false)
    |> Socket.assign(:pending_configuration, nil)
    |> Socket.assign(:push_registration_refs, %{})
    |> Socket.assign(:card_action_refs, %{})
    |> Socket.assign(:terminal_control_refs, %{})
    |> Socket.assign(:terminal_delete_tombstones, %{})
    |> Socket.assign(:mobile_terminal, nil)
    |> Socket.assign(:terminal_baseline_generation, 0)
    |> Socket.assign(:timing_context, timing_context)
    |> Socket.assign(:render_ready_generation, nil)
    |> Socket.assign(:transport_ready?, true)
    |> Socket.assign(:accepted_mobile_snapshot_version, nil)
    |> Socket.assign(:accepted_mobile_snapshot_origin_id, nil)
    |> Socket.assign(:expected_mobile_snapshot_origin_id, "origin-1")
  end

  defp mobile_snapshot(socket, version, cards \\ [], extras \\ %{}) do
    context = socket.assigns.timing_context

    Map.merge(
      %{
        "version" => version,
        "connection_generation" => context.generation,
        "connection_cycle" => Atom.to_string(context.cycle),
        "origin" => %{"id" => "origin-1", "display_name" => "Devbox"},
        "cards" => cards
      },
      extras
    )
  end

  defp terminal_control_reply(status, grant \\ "one-time-secret") do
    %{
      "schema" => "mobile_terminal_v1",
      "status" => status,
      "mode" => "read",
      "channel_topic" => "mobile_terminal:lease-1",
      "lease" => %{
        "id" => "lease-1",
        "lifecycle_generation" => "lifecycle-1",
        "workspace_id" => "ws-1",
        "expires_at" => "2026-08-05T00:00:00Z"
      },
      "child_grant" => %{
        "token" => grant,
        "expires_at" => "2026-08-05T00:00:00Z"
      }
    }
  end

  defp terminal_state(subscriber) do
    %{
      subscriber: subscriber,
      workspace_id: "ws-1",
      status: :live,
      lease: %{
        id: "lease-1",
        lifecycle_generation: "lifecycle-1",
        workspace_id: "ws-1",
        expires_at: "2026-08-05T00:00:00Z"
      },
      channel_topic: "mobile_terminal:lease-1",
      child_grant: "one-time-secret",
      grant_expires_at: "2026-08-05T00:00:00Z",
      connection_generation: "connection-1",
      stream: :opaque_stream,
      control_ref: nil,
      retry_attempt: 0,
      retry_token: nil,
      retry_timer: nil
    }
  end

  defp terminal_stream_socket(push_sink, subscriber) do
    socket =
      socket_with_subscriber("mobile:user:me", subscriber)
      |> Socket.put_join_config("mobile:user:me", %{})
      |> put_in([Access.key(:joins), "mobile:user:me", Access.key(:status)], :joined)
      |> Map.put(:channel_pid, push_sink)

    generation = socket.assigns.timing_context.generation

    {:ok, stream} =
      MobileTerminalStream.new(
        lease_id: "lease-1",
        lifecycle_generation: "lifecycle-1",
        connection_generation: generation
      )

    terminal =
      subscriber
      |> terminal_state()
      |> Map.put(:stream, stream)
      |> Map.put(:connection_generation, generation)
      |> Map.put(:status, :awaiting_baseline)

    Socket.assign(socket, :mobile_terminal, terminal)
  end

  defp terminal_frame(event, bytes, connection_generation, offset) do
    %{
      "schema" => "mobile_terminal_v1",
      "event" => event,
      "mode" => "read",
      "lease_id" => "lease-1",
      "lifecycle_generation" => "lifecycle-1",
      "connection_generation" => connection_generation,
      "stream_generation" => "stream-1",
      "offset" => offset,
      "next_offset" => offset + byte_size(bytes),
      "bytes_base64" => Base.encode64(bytes),
      "truncated" => false
    }
  end

  def handle_feed_stage(_event, measurements, metadata, subscriber) do
    send(subscriber, {:feed_stage, measurements, metadata})
  end

  defp start_push_sink(subscriber) do
    start_supervised!({Task, fn -> push_sink_loop(subscriber) end})
  end

  defp push_sink_loop(subscriber) do
    receive do
      {:"$gen_call", from,
       {:__slipstream_command__, %Slipstream.Commands.PushMessage{} = command}} ->
        send(subscriber, {:push_message, command})
        GenServer.reply(from, "push-ref")
        push_sink_loop(subscriber)

      {:__slipstream_command__, command} ->
        send(subscriber, {:connection_command, command})
        push_sink_loop(subscriber)
    end
  end
end
