defmodule CaseinMob.SessionClientBootTest do
  use ExUnit.Case, async: false

  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig
  alias CaseinMob.ConnectionTiming

  setup do
    if Process.whereis(Mob.State) == nil do
      start_supervised!(Mob.State)
    end

    SessionConfig.clear_all()
    ConnectionTiming.reset()

    on_exit(fn ->
      if Process.whereis(Mob.State), do: SessionConfig.clear_all()
      ConnectionTiming.reset()
    end)
  end

  test "restores persisted credentials and preconnects exactly once before the first watcher" do
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
    assert socket.assigns.connecting?
    assert socket.channel_config.test_mode?
    assert_receive :connect_started

    assert {:noreply, socket} =
             SessionClient.handle_cast({:watch_mobile_cards, self()}, socket)

    assert socket.assigns.subscribers["mobile:user:me"] == MapSet.new([self()])
    assert socket.assigns.connecting?
    assert socket.channel_config.test_mode?
    refute_receive :connect_started

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

  test "production reconnect backoff remains bounded below the five-second target" do
    SessionConfig.put_pairing("http://127.0.0.1:1", "stored-token")
    assert {:ok, socket} = SessionClient.init([])
    assert socket.channel_config.reconnect_after_msec == [250, 500, 1_000, 2_000]
    assert Enum.sum(socket.channel_config.reconnect_after_msec) == 3_750
  end

  test "connection timing emits only bounded stages and completes on authoritative join" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein_mob, :connection, :stage],
        &__MODULE__.handle_connection_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    ConnectionTiming.start_boot()
    SessionConfig.put_pairing("http://127.0.0.1:1", "must-not-appear")
    assert {:ok, socket} = SessionClient.init(test_mode?: true)
    assert {:noreply, socket} = SessionClient.handle_cast({:watch_mobile_cards, self()}, socket)
    assert {:ok, socket} = SessionClient.handle_connect(socket)
    assert {:ok, socket} = SessionClient.handle_join("mobile:user:me", %{"cards" => []}, socket)

    stages = collect_stages([])
    assert :configuration_restored in stages
    assert :connect_requested in stages
    assert :transport_connected in stages
    assert :authoritative_cards_joined in stages
    assert socket.assigns.timing_started_at == nil

    refute inspect(stages) =~ "must-not-appear"
    refute inspect(stages) =~ "127.0.0.1"
  end

  def handle_connect_start(_event, _measurements, _metadata, subscriber) do
    send(subscriber, :connect_started)
  end

  def handle_connection_stage(_event, measurements, metadata, subscriber) do
    send(subscriber, {:connection_stage, measurements, metadata})
  end

  defp collect_stages(acc) do
    receive do
      {:connection_stage, %{elapsed_ms: elapsed_ms}, %{cycle: cycle, stage: stage}}
      when is_integer(elapsed_ms) and cycle in [:cold, :reconnect] ->
        collect_stages([stage | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
