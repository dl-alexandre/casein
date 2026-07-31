defmodule CaseinMob.SessionClientTest do
  use ExUnit.Case, async: true

  alias CaseinMob.ConnectionTiming
  alias CaseinMob.SessionClient
  alias Slipstream.Socket

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
               {:configure, "http://127.0.0.1:1", "new-token"},
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

    assert_receive {:mobile_cards_status, :disconnected}
    assert_receive {:push_registration_status, :user, {:error, :host_switched}}

    assert_receive {:card_action_result, "needs_review:old-ws:run-1", {:error, :host_switched}}
  end

  test "explicitly activating the current origin preserves watchers and requests fresh connection" do
    socket =
      socket_with_subscriber("mobile:user:me", self())
      |> Socket.assign(:url, "http://127.0.0.1:1")
      |> Socket.assign(:token, "same-token")

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:activate_origin, "http://127.0.0.1:1", "same-token"},
               socket
             )

    assert socket.assigns.subscribers["mobile:user:me"] == MapSet.new([self()])
    assert socket.assigns.url == "http://127.0.0.1:1"
    assert socket.assigns.token == "same-token"
    assert socket.assigns.connecting?
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
    socket = socket_with_subscriber("mobile:user:me", self())

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

    socket = socket_with_subscriber("mobile:user:me", self())
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
    |> Socket.assign(:connecting?, false)
    |> Socket.assign(:push_registration_refs, %{})
    |> Socket.assign(:card_action_refs, %{})
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

  def handle_feed_stage(_event, measurements, metadata, subscriber) do
    send(subscriber, {:feed_stage, measurements, metadata})
  end
end
