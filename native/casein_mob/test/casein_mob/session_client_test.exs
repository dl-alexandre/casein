defmodule CaseinMob.SessionClientTest do
  use ExUnit.Case, async: true

  alias CaseinMob.SessionClient
  alias Slipstream.Socket

  test "mobile card topic join and pushes notify subscribers" do
    socket = socket_with_subscriber("mobile:user:me", self())
    snapshot = %{"cards" => [%{"id" => "needs_review:ws-1:run-1"}]}

    assert {:ok, ^socket} = SessionClient.handle_join("mobile:user:me", snapshot, socket)

    assert_receive {:mobile_cards_snapshot, ^snapshot}
    assert_receive {:mobile_cards_status, :joined}

    next_snapshot = %{"cards" => []}

    assert {:ok, ^socket} =
             SessionClient.handle_message(
               "mobile:user:me",
               "cards_snapshot",
               next_snapshot,
               socket
             )

    assert_receive {:mobile_cards_snapshot, ^next_snapshot}
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

    assert {:ok, _socket} = SessionClient.handle_disconnect({:error, :econnrefused}, socket)

    assert_receive {:mobile_cards_status, {:disconnected, :network_unavailable}}
    assert_receive {:session_status, "ws-1", {:disconnected, :network_unavailable}}
  end

  test "mobile card stream reports disconnected then joined after recovery" do
    socket = socket_with_subscriber("mobile:user:me", self())

    assert {:ok, socket} = SessionClient.handle_disconnect(:closed, socket)
    assert_receive {:mobile_cards_status, :disconnected}

    snapshot = %{"cards" => [%{"id" => "in_progress:ws-1:run-1"}]}

    assert {:ok, ^socket} = SessionClient.handle_join("mobile:user:me", snapshot, socket)

    assert_receive {:mobile_cards_snapshot, ^snapshot}
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

    socket =
      socket_with_subscribers(%{
        "mobile:user:me" => MapSet.new([self(), other]),
        "session:ws-1" => MapSet.new([self()])
      })

    assert {:noreply, socket} =
             SessionClient.handle_info({:DOWN, make_ref(), :process, self(), :normal}, socket)

    assert socket.assigns.subscribers == %{
             "mobile:user:me" => MapSet.new([other])
           }
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

    assert {:noreply, socket} =
             SessionClient.handle_cast(
               {:configure, "http://127.0.0.1:1", "new-token"},
               socket
             )

    assert socket.assigns.url == "http://127.0.0.1:1"
    assert socket.assigns.token == "new-token"
    assert socket.assigns.subscribers == %{}
    assert socket.assigns.push_registration_refs == %{}
    assert socket.assigns.card_action_refs == %{}

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

  test "an unrelated reply ref is ignored" do
    socket = socket_with_subscriber("mobile:user:me", self())
    assert {:ok, _socket} = SessionClient.handle_reply("unknown-ref", :ok, socket)
    refute_receive {:card_action_result, _card_id, _result}
  end

  defp socket_with_subscriber(topic, subscriber) do
    socket_with_subscribers(%{topic => MapSet.new([subscriber])})
  end

  defp socket_with_subscribers(subscribers) do
    Socket.new()
    |> Socket.assign(:subscribers, subscribers)
    |> Socket.assign(:url, nil)
    |> Socket.assign(:token, nil)
    |> Socket.assign(:connecting?, false)
    |> Socket.assign(:push_registration_refs, %{})
    |> Socket.assign(:card_action_refs, %{})
  end
end
