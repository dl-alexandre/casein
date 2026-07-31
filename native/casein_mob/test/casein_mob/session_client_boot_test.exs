defmodule CaseinMob.SessionClientBootTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CaseinMob.ConnectionTiming
  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig

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

    query = URI.decode_query(socket.channel_config.uri.query)
    assert query["connection_cycle"] == "cold"
    assert byte_size(query["connection_generation"]) == 22
    assert query["token"] == "stored-token"
    initial_generation = query["connection_generation"]

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

    reconnect_query = URI.decode_query(reconnecting.channel_config.uri.query)
    assert reconnect_query["connection_cycle"] == "reconnect"
    assert byte_size(reconnect_query["connection_generation"]) == 22
    refute reconnect_query["connection_generation"] == initial_generation

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

  test "first authoritative snapshot may perform the one-time legacy origin upgrade" do
    SessionConfig.put_pairing("http://127.0.0.1:1", "stored-token")
    assert {:ok, %{origin_id: "legacy_" <> _rest}} = SessionConfig.connection()
    assert {:ok, socket} = SessionClient.init(test_mode?: true)
    assert {:ok, socket} = SessionClient.handle_connect(socket)
    context = socket.assigns.timing_context

    snapshot = %{
      "version" => 0,
      "connection_generation" => context.generation,
      "connection_cycle" => Atom.to_string(context.cycle),
      "origin" => %{"id" => "canonical-origin", "display_name" => "Devbox"},
      "cards" => []
    }

    assert {:ok, socket} = SessionClient.handle_join("mobile:user:me", snapshot, socket)
    assert socket.assigns.accepted_mobile_snapshot_origin_id == "canonical-origin"
    assert {:ok, %{origin_id: "canonical-origin"}} = SessionConfig.connection()
  end

  test "production reconnect backoff remains bounded below the five-second target" do
    SessionConfig.put_pairing("http://127.0.0.1:1", "stored-token")
    assert {:ok, socket} = SessionClient.init([])
    assert socket.channel_config.reconnect_after_msec == [250, 500, 1_000, 2_000]
    assert Enum.sum(socket.channel_config.reconnect_after_msec) == 3_750
  end

  test "connection timing emits the shared privacy-safe schema through authoritative join" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_connection_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    ConnectionTiming.start_boot()
    boot_generation = ConnectionTiming.boot_context().generation

    ConnectionTiming.boot_stage(:dns_ready,
      outcome: :skipped,
      reason_code: :dns_ip_literal
    )

    ConnectionTiming.boot_stage(:dependencies_ready)
    SessionConfig.put_pairing("http://127.0.0.1:1", "must-not-appear")
    assert {:ok, socket} = SessionClient.init(test_mode?: true)
    assert socket.assigns.timing_context.generation == boot_generation
    assert ConnectionTiming.boot_context() == nil

    # App-side stages after the handoff cannot fork or advance this chain.
    assert :ok = ConnectionTiming.boot_stage(:database_ready)

    assert {:noreply, socket} = SessionClient.handle_cast({:watch_mobile_cards, self()}, socket)
    assert {:ok, socket} = SessionClient.handle_connect(socket)
    context = socket.assigns.timing_context
    {:ok, profile} = SessionConfig.connection()

    snapshot = %{
      "version" => 0,
      "connection_generation" => context.generation,
      "connection_cycle" => Atom.to_string(context.cycle),
      "origin" => %{"id" => profile.origin_id, "display_name" => "Devbox"},
      "cards" => []
    }

    assert {:ok, socket} = SessionClient.handle_join("mobile:user:me", snapshot, socket)

    events = collect_stages([])
    stages = Enum.map(events, fn {_measurements, metadata} -> metadata.stage end)
    assert :app_start in stages
    assert :dependencies_ready in stages
    assert :profile_restored in stages
    assert :connect_requested in stages
    assert :transport_connected in stages
    assert :mobile_join_replied in stages
    assert :snapshot_received in stages
    assert :snapshot_accepted in stages
    assert socket.assigns.accepted_mobile_snapshot_version == 0
    assert Enum.count(stages, &(&1 == :dns_resolved)) == 1
    refute :database_ready in stages

    assert events
           |> Enum.map(fn {_measurements, metadata} -> metadata.connection_generation end)
           |> Enum.uniq() == [boot_generation]

    assert {_measurements,
            %{
              stage: :dns_resolved,
              outcome: :skipped,
              reason_code: :dns_ip_literal,
              platform: :unknown
            }} =
             Enum.find(events, fn {_measurements, metadata} -> metadata.stage == :dns_resolved end)

    assert Enum.all?(events, fn {measurements, metadata} ->
             is_number(measurements.duration_ms) and measurements.duration_ms >= 0 and
               is_number(measurements.elapsed_ms) and measurements.elapsed_ms >= 0 and
               measurements.count == 1 and metadata.schema_version == 1 and
               metadata.component == :native and metadata.cycle in [:cold, :reconnect] and
               metadata.outcome in [:started, :succeeded, :failed, :skipped] and
               is_binary(metadata.connection_generation) and
               byte_size(metadata.connection_generation) == 22
           end)

    encoded_events = inspect(events)
    refute encoded_events =~ "must-not-appear"
    refute encoded_events =~ "127.0.0.1"
    refute encoded_events =~ "/socket/websocket"
  end

  test "standalone session client owns and records cold DNS without an app handoff" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_connection_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    SessionConfig.put_pairing("http://127.0.0.1:1", "must-not-appear")
    assert {:ok, socket} = SessionClient.init(test_mode?: true)

    events = collect_stages([])

    assert [
             {_measurements,
              %{
                stage: :dns_resolved,
                outcome: :skipped,
                reason_code: :dns_ip_literal,
                connection_generation: generation
              }}
           ] =
             Enum.filter(events, fn {_measurements, metadata} ->
               metadata.stage == :dns_resolved
             end)

    assert generation == socket.assigns.timing_context.generation
    assert ConnectionTiming.boot_context() == nil
  end

  test "feed telemetry and logs ignore URL, token, content, and raw error options" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_connection_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    context = ConnectionTiming.new_context(:cold)

    log =
      capture_log([level: :debug], fn ->
        ConnectionTiming.record(context, :connect_requested,
          url: "https://sensitive.example/socket/websocket",
          token: "super-secret",
          content: "private card content",
          raw_error: {:tls_alert, "private"},
          outcome: "unbounded-secret-outcome",
          reason_code: {:unbounded, "secret-reason"}
        )
      end)

    assert_receive {:connection_stage, measurements, metadata}
    assert metadata.connection_generation == context.generation
    assert metadata.outcome == :failed
    assert metadata.reason_code == :none
    assert log =~ "connection_generation=#{context.generation}"

    emitted = inspect({measurements, metadata, log})
    refute emitted =~ "sensitive.example"
    refute emitted =~ "super-secret"
    refute emitted =~ "private card content"
    refute emitted =~ "tls_alert"
    refute emitted =~ "unbounded-secret"
    refute emitted =~ "secret-reason"

    invalid_context = %{context | generation: "must-not-leak-generation"}

    invalid_log =
      capture_log([level: :debug], fn ->
        ConnectionTiming.record(invalid_context, :connect_requested)
      end)

    assert_receive {:connection_stage, _measurements, invalid_metadata}
    assert invalid_metadata.connection_generation == nil
    assert invalid_log =~ "connection_generation=uncorrelated"
    refute invalid_log =~ "must-not-leak-generation"
  end

  def handle_connect_start(_event, _measurements, _metadata, subscriber) do
    send(subscriber, :connect_started)
  end

  def handle_connection_stage(_event, measurements, metadata, subscriber) do
    send(subscriber, {:connection_stage, measurements, metadata})
  end

  defp collect_stages(acc) do
    receive do
      {:connection_stage, measurements, metadata} ->
        collect_stages([{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
