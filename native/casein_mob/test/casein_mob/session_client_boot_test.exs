Code.require_file("../../test_support/connection_timing_native_nif_mock.ex", __DIR__)

defmodule CaseinMob.SessionClientBootTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CaseinMob.ConnectionTiming
  alias CaseinMob.ConnectionTimingNativeNIFMock
  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig

  setup do
    previous_native_nif =
      Application.fetch_env(:casein_mob, :connection_timing_native_nif)

    previous_mob_beams_dir = System.get_env("MOB_BEAMS_DIR")

    Application.put_env(
      :casein_mob,
      :connection_timing_native_nif,
      ConnectionTimingNativeNIFMock
    )

    System.put_env("MOB_BEAMS_DIR", "connection-timing-test")
    ConnectionTimingNativeNIFMock.configure()

    if Process.whereis(Mob.State) == nil do
      start_supervised!(Mob.State)
    end

    SessionConfig.clear_all()
    ConnectionTiming.reset()

    on_exit(fn ->
      if Process.whereis(Mob.State), do: SessionConfig.clear_all()
      ConnectionTiming.reset()

      case previous_native_nif do
        {:ok, native_nif} ->
          Application.put_env(:casein_mob, :connection_timing_native_nif, native_nif)

        :error ->
          Application.delete_env(:casein_mob, :connection_timing_native_nif)
      end

      if previous_mob_beams_dir do
        System.put_env("MOB_BEAMS_DIR", previous_mob_beams_dir)
      else
        System.delete_env("MOB_BEAMS_DIR")
      end
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

  test "connection validation failures never log their raw reason" do
    assert {:ok, socket} = SessionClient.init(test_mode?: true)
    test_pid = self()

    log =
      capture_log([level: :warning], fn ->
        result =
          SessionClient.handle_cast(
            {:configure, "http://127.0.0.1:0", "must-not-appear"},
            socket
          )

        send(test_pid, {:configure_result, result})
      end)

    assert_receive {:configure_result, {:noreply, rejected}}
    refute rejected.assigns.connecting?
    refute log =~ "unparsable port value"
    refute log =~ "NimbleOptions.ValidationError"
    refute log =~ "must-not-appear"
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

  test "info-visible feed telemetry log contains only the privacy allowlisted schema" do
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
      capture_log([level: :info], fn ->
        ConnectionTiming.record(context, :connect_requested,
          url: "https://sensitive.example/socket/websocket",
          token: "super-secret",
          origin: "secret-origin",
          workspace: "secret-workspace",
          payload: %{"private" => "payload-content"},
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

    assert [line] =
             log
             |> String.split("\n", trim: true)
             |> Enum.filter(&String.contains?(&1, "mobile_feed_stage "))

    assert [_prefix, fields] = String.split(line, "mobile_feed_stage ", parts: 2)

    assert Enum.map(String.split(fields), fn field ->
             field
             |> String.split("=", parts: 2)
             |> List.first()
           end) == [
             "connection_generation",
             "cycle",
             "stage",
             "duration_ms",
             "elapsed_ms",
             "outcome",
             "reason_code"
           ]

    emitted = inspect({measurements, metadata, log})
    refute emitted =~ "sensitive.example"
    refute emitted =~ "super-secret"
    refute emitted =~ "secret-origin"
    refute emitted =~ "secret-workspace"
    refute emitted =~ "payload-content"
    refute emitted =~ "private card content"
    refute emitted =~ "tls_alert"
    refute emitted =~ "unbounded-secret"
    refute emitted =~ "secret-reason"

    invalid_context = %{context | generation: "must-not-leak-generation"}

    invalid_log =
      capture_log([level: :info], fn ->
        ConnectionTiming.record(invalid_context, :connect_requested)
      end)

    refute_receive {:connection_stage, _measurements, _invalid_metadata}
    refute invalid_log =~ "mobile_feed_stage"
    refute invalid_log =~ "must-not-leak-generation"
  end

  test "iOS feed telemetry uses the structured native sink exactly once with allowlisted fields" do
    context = ConnectionTiming.new_context(:cold)
    test_pid = self()
    ConnectionTimingNativeNIFMock.configure(platform: :ios, subscriber: self())

    logger_output =
      capture_log([level: :info], fn ->
        updated_context =
          ConnectionTiming.record(context, :connect_requested,
            url: "https://sensitive.example/socket/websocket",
            token: "super-secret",
            origin: "secret-origin",
            workspace: "secret-workspace",
            payload: %{"private" => "payload-content"},
            content: "private card content",
            raw_error: {:tls_alert, "private"},
            outcome: "unbounded-secret-outcome",
            reason_code: {:unbounded, "secret-reason"}
          )

        send(test_pid, {:updated_timing_context, updated_context})
      end)

    assert_receive {:native_feed_stage, generation, :cold, :connect_requested, duration_ms,
                    elapsed_ms, :failed, :none}

    assert generation == context.generation
    assert is_number(duration_ms) and duration_ms >= 0
    assert is_number(elapsed_ms) and elapsed_ms >= duration_ms
    refute_receive {:native_feed_stage, _, _, _, _, _, _, _}
    refute_receive {:native_generic_log, _, _}
    assert_receive {:updated_timing_context, updated_context}
    assert updated_context.last_at >= context.last_at
    refute logger_output =~ "mobile_feed_stage"

    emitted =
      inspect({generation, :cold, :connect_requested, duration_ms, elapsed_ms, :failed, :none})

    refute_private_timing_data(emitted)
  end

  test "iOS structured timing preserves stage duration and generation elapsed semantics" do
    context = ConnectionTiming.new_context(:reconnect)
    ConnectionTimingNativeNIFMock.configure(platform: :ios, subscriber: self())

    first_at = context.started_at + 2_500

    context =
      ConnectionTiming.record(context, :connect_requested,
        observed_at: first_at,
        outcome: :started
      )

    assert_receive {:native_feed_stage, generation, :reconnect, :connect_requested, 2.5, 2.5,
                    :started, :none}

    second_at = context.started_at + 9_000

    updated =
      ConnectionTiming.record(context, :transport_connected,
        observed_at: second_at,
        reason_code: :dns_resolved
      )

    assert_receive {:native_feed_stage, ^generation, :reconnect, :transport_connected, 6.5, 9.0,
                    :succeeded, :dns_resolved}

    assert updated.last_at == second_at
    refute_receive {:native_generic_log, _, _}
  end

  test "non-monotonic timing observations are dropped without advancing the generation" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_connection_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    context = ConnectionTiming.new_context(:reconnect)
    ConnectionTimingNativeNIFMock.configure(platform: :ios, subscriber: self())

    observed_at = context.started_at + 2_000

    accepted =
      ConnectionTiming.record(context, :connect_requested,
        observed_at: observed_at,
        outcome: :started
      )

    assert accepted.last_at == observed_at

    assert_receive {:connection_stage, %{duration_ms: 2.0}, %{stage: :connect_requested}}

    assert_receive {:native_feed_stage, _, :reconnect, :connect_requested, 2.0, 2.0, :started,
                    :none}

    assert ConnectionTiming.record(accepted, :transport_connected,
             observed_at: context.started_at + 1_000
           ) == accepted

    refute_receive {:connection_stage, _measurements, %{stage: :transport_connected}}
    refute_receive {:native_feed_stage, _, _, :transport_connected, _, _, _, _}
  end

  test "duplicate one-shot timing stages are dropped without advancing the generation" do
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
    ConnectionTimingNativeNIFMock.configure(platform: :ios, subscriber: self())

    accepted =
      ConnectionTiming.record(context, :transport_connected,
        observed_at: context.started_at + 2_000
      )

    assert_receive {:connection_stage, _measurements, %{stage: :transport_connected}}

    assert_receive {:native_feed_stage, _, :cold, :transport_connected, 2.0, 2.0, :succeeded,
                    :none}

    assert ConnectionTiming.record(accepted, :transport_connected,
             observed_at: context.started_at + 3_000
           ) == accepted

    refute_receive {:connection_stage, _measurements, %{stage: :transport_connected}}
    refute_receive {:native_feed_stage, _, _, :transport_connected, _, _, _, _}
  end

  test "snapshot timing stages remain repeatable within one generation" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_connection_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    context = ConnectionTiming.new_context(:reconnect)
    ConnectionTimingNativeNIFMock.configure(platform: :android, subscriber: self())

    first =
      ConnectionTiming.record(context, :snapshot_received,
        observed_at: context.started_at + 1_000
      )

    second =
      ConnectionTiming.record(first, :snapshot_received, observed_at: context.started_at + 2_000)

    assert second.last_at == context.started_at + 2_000

    assert_receive {:connection_stage, %{duration_ms: 1.0}, %{stage: :snapshot_received}}
    assert_receive {:connection_stage, %{duration_ms: 1.0}, %{stage: :snapshot_received}}

    assert_receive {:native_feed_stage, _, :reconnect, :snapshot_received, 1.0, 1.0, :succeeded,
                    :none}

    assert_receive {:native_feed_stage, _, :reconnect, :snapshot_received, 1.0, 2.0, :succeeded,
                    :none}
  end

  test "iOS structured timing skips envelopes rejected by the native schema" do
    context = ConnectionTiming.new_context(:reconnect)

    ConnectionTimingNativeNIFMock.configure(
      platform: :ios,
      subscriber: self(),
      stage_log_result: {:erlang_error, :badarg}
    )

    invalid_generation = %{context | generation: "not-a-canonical-generation"}
    observed_at = context.started_at + 1_000

    assert ConnectionTiming.record(invalid_generation, :connect_requested,
             observed_at: observed_at
           ) == invalid_generation

    over_native_limit = context.started_at + 2_147_483_648_000

    assert ConnectionTiming.record(context, :connect_requested, observed_at: over_native_limit) ==
             context

    duration_exceeds_elapsed = %{context | last_at: context.started_at - 1_000}

    assert ConnectionTiming.record(duration_exceeds_elapsed, :connect_requested,
             observed_at: observed_at
           ) == duration_exceeds_elapsed

    malformed_seen_stages = %{context | seen_stages: [:transport_connected]}

    assert ConnectionTiming.record(malformed_seen_stages, :connect_requested,
             observed_at: observed_at
           ) == malformed_seen_stages

    missing_generation = %{context | generation: nil}

    assert ConnectionTiming.record(missing_generation, :connect_requested,
             observed_at: observed_at
           ) == missing_generation

    corrupt_seen_stages = %{context | seen_stages: %MapSet{map: :not_a_map}}

    assert ConnectionTiming.record(corrupt_seen_stages, :connect_requested,
             observed_at: observed_at
           ) == corrupt_seen_stages

    refute_receive {:native_feed_stage, _, _, _, _, _, _, _}
    refute_receive {:native_generic_log, _, _}
  end

  test "Android feed telemetry uses the dedicated native stage sink" do
    context = ConnectionTiming.new_context(:reconnect)
    ConnectionTimingNativeNIFMock.configure(platform: :android, subscriber: self())

    log =
      capture_log([level: :info], fn ->
        ConnectionTiming.record(context, :transport_connected,
          observed_at: context.started_at + 4_000,
          url: "https://sensitive.example/socket/websocket",
          token: "super-secret",
          raw_error: {:tls_alert, "private"}
        )
      end)

    assert_receive {:native_feed_stage, generation, :reconnect, :transport_connected, 4.0, 4.0,
                    :succeeded, :none}

    assert generation == context.generation
    refute_receive {:native_feed_stage, _, _, _, _, _, _, _}
    refute_receive {:native_generic_log, _, _}
    refute log =~ "mobile_feed_stage"
    refute_private_timing_data(inspect({generation, log}))
  end

  test "unknown platforms keep Logger and record options cannot inject native logging" do
    test_pid = self()

    for platform <- [:unknown] do
      context = ConnectionTiming.new_context(:reconnect)

      ConnectionTimingNativeNIFMock.configure(
        platform: platform,
        subscriber: self()
      )

      log =
        capture_log([level: :info], fn ->
          ConnectionTiming.record(context, :transport_connected,
            timing_platform: :ios,
            timing_native_log_sink: fn level, line ->
              send(test_pid, {:injected_timing_log, platform, level, line})
            end
          )
        end)

      assert [_line] =
               log
               |> String.split("\n", trim: true)
               |> Enum.filter(&String.contains?(&1, "mobile_feed_stage "))
    end

    refute_receive {:native_feed_stage, _, _, _, _, _, _, _}
    refute_receive {:native_generic_log, _, _}
    refute_receive {:injected_timing_log, _, _, _}
  end

  test "not-loaded iOS native stage errors and exits preserve telemetry and context advancement" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_connection_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    for stage_log_result <- [
          {:nif_error, :not_loaded},
          {:nif_error, :nif_not_loaded},
          {:exit, :nif_not_loaded},
          {:exit, {:nif_not_loaded, :not_linked}}
        ] do
      context = ConnectionTiming.new_context(:cold)
      observed_at = context.last_at + 10_000

      ConnectionTimingNativeNIFMock.configure(
        platform: :ios,
        subscriber: self(),
        stage_log_result: stage_log_result
      )

      updated_context =
        ConnectionTiming.record(context, :connect_requested, observed_at: observed_at)

      assert updated_context.last_at == observed_at

      assert_receive {:connection_stage, %{duration_ms: 10.0},
                      %{platform: :ios, stage: :connect_requested}}

      generation = context.generation

      assert_receive {:native_feed_stage, ^generation, :cold, :connect_requested, duration_ms,
                      elapsed_ms, :succeeded, :none}

      assert duration_ms == 10.0
      assert elapsed_ms == 10.0
    end

    refute_receive {:native_feed_stage, _, _, _, _, _, _, _}
    refute_receive {:native_generic_log, _, _}
  end

  test "native stage sink failures never interrupt timing advancement or feed telemetry" do
    telemetry_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:casein, :mobile, :feed, :stage],
        &__MODULE__.handle_connection_stage/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    for stage_log_result <- [
          {:erlang_error, :unexpected_app_bug},
          {:exit, :unexpected_native_exit},
          {:ok, :unexpected_native_result}
        ] do
      ConnectionTimingNativeNIFMock.configure(
        platform: :ios,
        subscriber: self(),
        stage_log_result: stage_log_result
      )

      context = ConnectionTiming.new_context(:cold)
      observed_at = context.started_at + 1_000

      assert %{last_at: ^observed_at} =
               ConnectionTiming.record(context, :connect_requested, observed_at: observed_at)

      assert_receive {:connection_stage, %{duration_ms: 1.0},
                      %{platform: :ios, stage: :connect_requested}}

      generation = context.generation

      assert_receive {:native_feed_stage, ^generation, :cold, :connect_requested, 1.0, 1.0,
                      :succeeded, :none}
    end

    refute_receive {:native_generic_log, _, _}
  end

  test "the exact missing iOS native stage function is a soft failure" do
    context = ConnectionTiming.new_context(:cold)

    ConnectionTimingNativeNIFMock.configure(
      platform: :ios,
      subscriber: self(),
      stage_log_result:
        {:raise_undefined_function, ConnectionTimingNativeNIFMock, :log_mobile_feed_stage, 7}
    )

    updated = ConnectionTiming.record(context, :connect_requested, observed_at: context.last_at)
    assert updated.last_at == context.last_at
    generation = context.generation

    assert_receive {:native_feed_stage, ^generation, :cold, :connect_requested, duration_ms,
                    elapsed_ms, :succeeded, :none}

    assert duration_ms == 0.0
    assert elapsed_ms == 0.0
    refute_receive {:native_generic_log, _, _}
  end

  test "undefined calls raised by the native stage sink do not interrupt timing" do
    missing_dependency = CaseinMob.ConnectionTimingMissingLogDependency

    for stage_log_result <- [
          {:undefined_function, missing_dependency, :write, []},
          {:raise_undefined_function, ConnectionTimingNativeNIFMock, :log_mobile_feed_stage, 6}
        ] do
      ConnectionTimingNativeNIFMock.configure(
        platform: :ios,
        subscriber: self(),
        stage_log_result: stage_log_result
      )

      context = ConnectionTiming.new_context(:cold)
      observed_at = context.started_at + 1_000

      assert %{last_at: ^observed_at} =
               ConnectionTiming.record(context, :connect_requested, observed_at: observed_at)

      generation = context.generation

      assert_receive {:native_feed_stage, ^generation, :cold, :connect_requested, 1.0, 1.0,
                      :succeeded, :none}
    end
  end

  test "platform detection failures fall back without interrupting timing" do
    missing_dependency = CaseinMob.ConnectionTimingMissingPlatformDependency

    for platform_result <- [
          {:erlang_error, :unexpected_platform_bug},
          {:exit, :unexpected_platform_exit},
          {:undefined_function, missing_dependency, :read, []}
        ] do
      ConnectionTimingNativeNIFMock.configure(platform_result: platform_result)
      context = ConnectionTiming.new_context(:cold)
      observed_at = context.started_at + 1_000

      log =
        capture_log([level: :info], fn ->
          assert %{last_at: ^observed_at} =
                   ConnectionTiming.record(context, :connect_requested, observed_at: observed_at)
        end)

      assert log =~ "mobile_feed_stage"
      assert log =~ "connection_generation=#{context.generation}"
    end
  end

  test "not-loaded platform errors and exits fall back to the unknown Logger path" do
    for platform_result <- [{:nif_error, :not_loaded}, {:exit, :nif_not_loaded}] do
      ConnectionTimingNativeNIFMock.configure(platform_result: platform_result)

      log =
        capture_log([level: :info], fn ->
          ConnectionTiming.record(ConnectionTiming.new_context(:cold), :connect_requested)
        end)

      assert [_line] =
               log
               |> String.split("\n", trim: true)
               |> Enum.filter(&String.contains?(&1, "mobile_feed_stage "))
    end
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

  defp refute_private_timing_data(line) do
    refute line =~ "sensitive.example"
    refute line =~ "super-secret"
    refute line =~ "secret-origin"
    refute line =~ "secret-workspace"
    refute line =~ "payload-content"
    refute line =~ "private card content"
    refute line =~ "tls_alert"
    refute line =~ "unbounded-secret"
    refute line =~ "secret-reason"
  end
end
