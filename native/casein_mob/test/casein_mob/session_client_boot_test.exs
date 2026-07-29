defmodule CaseinMob.SessionClientBootTest do
  use ExUnit.Case, async: false

  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig

  setup do
    if Process.whereis(Mob.State) == nil do
      start_supervised!(Mob.State)
    end

    SessionConfig.clear_all()

    on_exit(fn ->
      if Process.whereis(Mob.State), do: SessionConfig.clear_all()
    end)
  end

  test "restores persisted credentials but waits for the first watcher to connect" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:slipstream, :client, :connect, :start],
        &__MODULE__.handle_connect_start/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    SessionConfig.put_pairing("http://127.0.0.1:1", "stored-token")

    assert {:ok, socket} = SessionClient.init(test_mode?: true)

    assert socket.assigns.url == "http://127.0.0.1:1"
    assert socket.assigns.token == "stored-token"
    refute socket.assigns.connecting?
    assert socket.channel_config == nil

    assert {:noreply, socket} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, socket)

    assert socket.assigns.subscribers["mobile:user:me"] == MapSet.new([self()])
    assert socket.assigns.connecting?
    assert socket.channel_config.test_mode?
    assert_receive :connect_started

    other = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(other, :kill) end)

    assert {:noreply, same_connection} =
             SessionClient.handle_cast({:watch_mobile_cards, other}, socket)

    assert same_connection.channel_config == socket.channel_config
    assert same_connection.assigns.connecting?
    refute_receive :connect_started

    assert {:ok, reconnecting} = SessionClient.handle_disconnect(:closed, same_connection)

    assert reconnecting.assigns.url == "http://127.0.0.1:1"
    assert reconnecting.assigns.token == "stored-token"

    assert reconnecting.assigns.subscribers["mobile:user:me"] ==
             MapSet.new([self(), other])

    assert reconnecting.assigns.connecting?
    assert_receive {:__slipstream_command__, %Slipstream.Commands.OpenConnection{}}
    refute_receive {:__slipstream_command__, %Slipstream.Commands.OpenConnection{}}
  end

  test "does not configure or connect without a persisted pairing" do
    assert {:ok, socket} = SessionClient.init(test_mode?: true)

    assert socket.assigns.url == nil
    assert socket.assigns.token == nil
    refute socket.assigns.connecting?
    assert socket.channel_config == nil
    refute_receive {:__slipstream_command__, %Slipstream.Commands.OpenConnection{}}
  end

  def handle_connect_start(_event, _measurements, _metadata, subscriber) do
    send(subscriber, :connect_started)
  end
end
