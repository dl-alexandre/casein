defmodule Casein.Mobile.FeedTimingSoakBridgeTest do
  use ExUnit.Case, async: true

  alias Casein.Mobile.{FeedTiming, FeedTimingAggregate, FeedTimingSoakBridge}

  @stages ~w(
    token_verified
    mobile_join_started
    mobile_join_replied
    workspace_watch_started
    workspace_watch_replied
    session_hydration_started
    session_hydration_finished
    clarification_hydration_finished
    observer_snapshot
    projection_broadcast
    snapshot_rendered
    push_queued
  )
  @outcomes ~w(started succeeded failed skipped)
  @reasons ~w(
    none
    user_token
    pairing_token
    device_link_token
    invalid_token
    mobile_join
    workspace_watch
    workspace_watched
    already_watched
    hydrated
    no_changes
    stale_hydration
    rendered
    pushed
    unauthorized
  )

  test "scope parser accepts only the fixed non-secret vocabulary" do
    assert {:ok, :ios, :cold} = FeedTimingSoakBridge.parse_scope(["ios", "cold"])

    assert {:ok, :android, :reconnect} =
             FeedTimingSoakBridge.parse_scope(["android", "reconnect"])

    assert {:ok, :ios, :origin_switch} =
             FeedTimingSoakBridge.parse_scope(["ios", "origin_switch"])

    invalid = [
      [],
      ["ios"],
      ["ios", "cold", "extra"],
      ["IOS", "cold"],
      ["ios", "COLD"],
      ["web", "cold"],
      ["ios", "unknown"],
      [:ios, :cold],
      "ios cold"
    ]

    assert Enum.all?(invalid, fn args ->
             FeedTimingSoakBridge.parse_scope(args) == {:error, :invalid_request}
           end)
  end

  test "cookie parser extracts exactly one bounded literal assignment without reflecting neighbors" do
    cookie = String.duplicate("a7", 24)
    unrelated_secret = "OTHER_SECRET=must-not-reflect"

    contents = "COMMENT=value\n#{unrelated_secret}\nRELEASE_COOKIE=#{cookie}\nPORT=4000\n"

    assert {:ok, ^cookie} = FeedTimingSoakBridge.parse_cookie(contents)
    refute inspect(FeedTimingSoakBridge.parse_cookie(contents)) =~ unrelated_secret

    invalid = [
      "PORT=4000\n",
      "RELEASE_COOKIE=short\n",
      "RELEASE_COOKIE=#{cookie}\nRELEASE_COOKIE=#{cookie}\n",
      " RELEASE_COOKIE=#{cookie}\n",
      "export RELEASE_COOKIE=#{cookie}\n",
      "RELEASE_COOKIE='#{cookie}'\n",
      "RELEASE_COOKIE=#{cookie}!\n",
      "RELEASE_COOKIE=#{cookie}\r\n",
      "RELEASE_COOKIE=#{cookie}\nOTHER=bad\0value\n",
      String.duplicate("X", 65_537)
    ]

    Enum.each(invalid, fn contents ->
      assert {:error, :invalid_credential} = FeedTimingSoakBridge.parse_cookie(contents)
      refute inspect(FeedTimingSoakBridge.parse_cookie(contents)) =~ cookie
    end)
  end

  test "cookie parser accepts hex or one unpadded Base64 alphabet without mixing" do
    accepted = [
      String.duplicate("a7", 24),
      String.duplicate("Ab_9-", 10),
      String.duplicate("Ab+/", 12),
      String.duplicate("A", 32),
      String.duplicate("+/", 64)
    ]

    Enum.each(accepted, fn cookie ->
      assert {:ok, ^cookie} =
               FeedTimingSoakBridge.parse_cookie("RELEASE_COOKIE=#{cookie}\n")
    end)

    invalid_alphabet = [
      String.duplicate("A", 31),
      String.duplicate("A", 129),
      String.duplicate("A", 30) <> "_+",
      String.duplicate("A", 30) <> "-/",
      String.duplicate("A", 16) <> " " <> String.duplicate("A", 16),
      String.duplicate("A", 16) <> "\t" <> String.duplicate("A", 16),
      "=" <> String.duplicate("A", 31),
      String.duplicate("A", 16) <> "=" <> String.duplicate("A", 16),
      String.duplicate("A", 31) <> "=",
      String.duplicate("A", 30) <> "=="
    ]

    Enum.each(invalid_alphabet, fn cookie ->
      assert {:error, :invalid_credential} =
               FeedTimingSoakBridge.parse_cookie("RELEASE_COOKIE=#{cookie}\n")
    end)
  end

  test "credential stat requires one private regular file without assuming a numeric owner" do
    private = %File.Stat{type: :regular, links: 1, mode: 0o100600, uid: 1_001, gid: 1_001}

    assert FeedTimingSoakBridge.private_credential_stat?(private)

    refute FeedTimingSoakBridge.private_credential_stat?(%{private | links: 2})
    refute FeedTimingSoakBridge.private_credential_stat?(%{private | mode: 0o100640})
    refute FeedTimingSoakBridge.private_credential_stat?(%{private | mode: 0o100604})
    refute FeedTimingSoakBridge.private_credential_stat?(%{private | type: :symlink})
    refute FeedTimingSoakBridge.private_credential_stat?(:malformed)
  end

  test "generation parser accepts exactly twenty canonical LF-terminated unique lines" do
    generations = generations(1..20)
    input = Enum.map_join(generations, "", &(&1 <> "\n"))

    assert byte_size(input) == 460
    assert {:ok, ^generations} = FeedTimingSoakBridge.parse_generations(input)

    invalid = [
      Enum.map_join(Enum.take(generations, 19), "", &(&1 <> "\n")),
      input <> "\n",
      String.trim_trailing(input, "\n"),
      String.replace(input, "\n", "\r\n"),
      Enum.map_join(List.replace_at(generations, 19, hd(generations)), "", &(&1 <> "\n")),
      Enum.map_join(List.replace_at(generations, 19, "not-canonical"), "", &(&1 <> "\n")),
      input <> generation(21) <> "\n",
      :binary.replace(input, "\n", "\0", [:global])
    ]

    assert Enum.all?(invalid, fn contents ->
             FeedTimingSoakBridge.parse_generations(contents) == {:error, :invalid_request}
           end)
  end

  test "aggregate encoder allows only scoped aggregate JSON with no supplied IDs or cookie" do
    generations = generations(41..60)
    cookie = String.duplicate("e8", 24)
    aggregate = aggregate_fixture()

    assert {:ok, encoded} =
             FeedTimingSoakBridge.encode_aggregate(
               aggregate,
               generations,
               cookie,
               :ios,
               :cold
             )

    assert {:ok, ^aggregate} = Jason.decode(encoded)
    refute encoded =~ cookie
    refute Enum.any?(generations, &String.contains?(encoded, &1))

    populated_aggregate =
      aggregate
      |> aggregate_with_records(10, false)
      |> put_in(
        ["optional_measurements", "card_count"],
        %{"sample_count" => 10, "min" => 0, "p50" => 1, "p95" => 2, "max" => 3}
      )

    assert {:ok, _encoded} =
             FeedTimingSoakBridge.encode_aggregate(
               populated_aggregate,
               generations,
               cookie,
               :ios,
               :cold
             )

    leaking_id =
      put_in(
        aggregate["stage_timings"]["token_verified"]["duration_ms"]["p50"],
        hd(generations)
      )

    leaking_cookie = put_in(aggregate["reason_counts"]["none"], cookie)

    arbitrary_nested_text =
      put_in(
        aggregate["stage_timings"]["token_verified"]["elapsed_ms"]["p50"],
        "privacy-regression-sentinel"
      )

    malformed_numeric_values =
      for value <- [-1, true, :nan, "NaN", 86_400_001] do
        put_in(
          populated_aggregate["stage_timings"]["token_verified"]["duration_ms"]["max"],
          value
        )
      end

    forbidden_nested_key =
      update_in(aggregate["stage_timings"]["token_verified"], fn timing ->
        Map.put(timing, "unexpected", 1)
      end)

    inconsistent_empty_summary =
      put_in(
        aggregate["stage_timings"]["token_verified"]["duration_ms"]["max"],
        1
      )

    unordered_summary =
      populated_aggregate
      |> put_in(
        ["stage_timings", "token_verified", "duration_ms"],
        %{"min" => 3, "p50" => 2, "p95" => 4, "max" => 5}
      )

    missing_p95 =
      put_in(
        populated_aggregate["stage_timings"]["token_verified"]["duration_ms"]["p95"],
        nil
      )

    premature_p95 =
      aggregate
      |> aggregate_with_records(1, false)
      |> put_in(
        ["stage_timings", "token_verified", "duration_ms"],
        %{"min" => 1, "p50" => 1, "p95" => 1, "max" => 1}
      )

    empty_optional_summary =
      put_in(
        aggregate["optional_measurements"]["card_count"],
        %{"sample_count" => 0, "min" => nil, "p50" => nil, "p95" => nil, "max" => nil}
      )

    oversized_nested_map =
      update_in(aggregate["optional_measurements"], fn measurements ->
        Map.put(measurements, String.duplicate("x", 70_000), %{})
      end)

    rejected_aggregates =
      [
        leaking_id,
        leaking_cookie,
        arbitrary_nested_text,
        forbidden_nested_key,
        inconsistent_empty_summary,
        unordered_summary,
        missing_p95,
        premature_p95,
        empty_optional_summary,
        oversized_nested_map,
        %{aggregate | "platform" => "android"},
        %{aggregate | "cycle" => "reconnect"},
        Map.put(aggregate, "unexpected", true)
      ] ++ malformed_numeric_values

    for rejected <- rejected_aggregates do
      assert {:error, :invalid_aggregate} =
               FeedTimingSoakBridge.encode_aggregate(
                 rejected,
                 generations,
                 cookie,
                 :ios,
                 :cold
               )
    end

    refute FeedTimingSoakBridge.encoded_aggregate_size_valid?(:not_binary)
    assert FeedTimingSoakBridge.encoded_aggregate_size_valid?(String.duplicate("x", 65_536))
    refute FeedTimingSoakBridge.encoded_aggregate_size_valid?(String.duplicate("x", 65_537))
  end

  test "aggregate encoder enforces exact cross-map matched-record invariants" do
    generations = generations(61..80)
    cookie = String.duplicate("c9", 24)
    empty_partial = aggregate_fixture()

    positive_partial =
      empty_partial
      |> aggregate_with_records(1, false)
      |> put_in(
        ["optional_measurements", "card_count"],
        %{"sample_count" => 1, "min" => 1, "p50" => 1, "p95" => nil, "max" => 1}
      )

    positive_match =
      empty_partial
      |> aggregate_with_records(20, true)
      |> put_in(
        ["optional_measurements", "card_count"],
        %{"sample_count" => 20, "min" => 1, "p50" => 2, "p95" => 3, "max" => 4}
      )

    for accepted <- [empty_partial, positive_partial, positive_match] do
      assert {:ok, _encoded} =
               FeedTimingSoakBridge.encode_aggregate(
                 accepted,
                 generations,
                 cookie,
                 :ios,
                 :cold
               )
    end

    {:ok, unexpected_record} =
      FeedTiming.sanitize_event(
        %{duration_ms: 1, elapsed_ms: 2, count: 1},
        %{
          schema_version: 1,
          component: :server,
          platform: :ios,
          cycle: :cold,
          stage: :token_verified,
          outcome: :succeeded,
          reason_code: :none,
          connection_generation: generation(81)
        }
      )

    assert {:ok, request} = FeedTimingAggregate.validate_request(generations, :ios, :cold)

    assert {:ok, unexpected_only, []} =
             FeedTimingAggregate.build([{1, unexpected_record}], request)

    assert unexpected_only["observed_generation_count"] == 1
    assert unexpected_only["stage_timings"]["token_verified"]["sample_count"] == 0

    assert {:ok, _encoded} =
             FeedTimingSoakBridge.encode_aggregate(
               unexpected_only,
               generations,
               cookie,
               :ios,
               :cold
             )

    stage_outcome_mismatch =
      put_in(positive_match["stage_timings"]["token_verified"]["sample_count"], 19)

    outcome_reason_mismatch = put_in(positive_match["outcome_counts"]["succeeded"], 19)
    reason_stage_mismatch = put_in(positive_match["reason_counts"]["none"], 19)

    optional_exceeds_total =
      put_in(positive_match["optional_measurements"]["card_count"]["sample_count"], 21)

    matched_with_too_few_records = aggregate_with_records(empty_partial, 19, true)

    matched_without_observed_generation =
      Map.put(positive_partial, "observed_generation_count", 0)

    for rejected <- [
          stage_outcome_mismatch,
          outcome_reason_mismatch,
          reason_stage_mismatch,
          optional_exceeds_total,
          matched_with_too_few_records,
          matched_without_observed_generation
        ] do
      assert {:error, :invalid_aggregate} =
               FeedTimingSoakBridge.encode_aggregate(
                 rejected,
                 generations,
                 cookie,
                 :ios,
                 :cold
               )
    end
  end

  test "target parser accepts only the canonical current-socket instance shape and safe host" do
    assert {:ok, target} =
             FeedTimingSoakBridge.target_from_link(
               "/run/casein/instances/0123456789abcdef.sock",
               "devbox"
             )

    assert target.socket_path == "/run/casein/instances/0123456789abcdef.sock"
    assert target.instance_id == "0123456789abcdef"
    assert target.node_name == "casein_0123456789abcdef@devbox"

    invalid = [
      {"instances/0123456789abcdef.sock", "devbox"},
      {"/run/casein/instances/0123456789ABCDEF.sock", "devbox"},
      {"/run/casein/instances/0123456789abcdef.sock.extra", "devbox"},
      {"/run/casein/other/0123456789abcdef.sock", "devbox"},
      {"/run/casein/instances/../../tmp/0123456789abcdef.sock", "devbox"},
      {"/run/casein/instances/0123456789abcdef.sock", "-devbox"},
      {"/run/casein/instances/0123456789abcdef.sock", "devbox."},
      {"/run/casein/instances/0123456789abcdef.sock", "bad host"},
      {"/run/casein/instances/0123456789abcdef.sock", String.duplicate("a", 64)}
    ]

    assert Enum.all?(invalid, fn {link, host} ->
             FeedTimingSoakBridge.target_from_link(link, host) ==
               {:error, :invalid_target}
           end)

    socket = %File.Stat{type: :other, mode: 0o140600}
    assert FeedTimingSoakBridge.socket_target_stat_valid?(socket)
    refute FeedTimingSoakBridge.socket_target_stat_valid?(%{socket | mode: 0o010600})
    refute FeedTimingSoakBridge.socket_target_stat_valid?(%{socket | type: :symlink})
    refute FeedTimingSoakBridge.socket_target_stat_valid?(%{socket | type: :regular})
  end

  test "collection opens the fence, signals ready exactly once, then reads stdin and finishes" do
    target = %{node: :target, socket_path: "/fixed", instance_id: "fixed"}
    generations = generations(101..120)
    aggregate = %{"component" => "server"}
    test_process = self()

    reader = fn ->
      send(test_process, :read_stdin)
      {:ok, generations}
    end

    ready = fn ->
      send(test_process, {:ready, FeedTimingSoakBridge.ready_line()})
      :ok
    end

    rpc = fn ^target, command ->
      send(test_process, {:rpc, command})

      case command do
        {:begin, :ios, :cold} -> {:ok, :opaque_fence}
        {:finish, :opaque_fence, ^generations, :ios, :cold} -> {:ok, aggregate}
      end
    end

    recheck = fn ^target ->
      send(test_process, :recheck)
      :ok
    end

    assert {:ok, ^aggregate, ^generations} =
             FeedTimingSoakBridge.collect_for(
               target,
               :ios,
               :cold,
               ready,
               reader,
               rpc,
               recheck
             )

    assert_receive {:rpc, {:begin, :ios, :cold}}
    assert_receive {:ready, "CASEIN_MOBILE_FEED_SOAK_READY\n"}
    assert_receive :read_stdin
    assert_receive :recheck
    assert_receive {:rpc, {:finish, :opaque_fence, ^generations, :ios, :cold}}
    assert_receive :recheck
    refute_receive _unexpected
  end

  test "an unavailable readiness channel retires the fence without reading stdin" do
    target = %{node: :target}
    test_process = self()

    rpc = fn ^target, command ->
      send(test_process, {:rpc, command})

      case command do
        {:begin, :ios, :cold} -> {:ok, :opaque_fence}
        {:finish, :opaque_fence, [], :ios, :cold} -> {:error, :invalid_request}
      end
    end

    assert {:error, :collection_failed} =
             FeedTimingSoakBridge.collect_for(
               target,
               :ios,
               :cold,
               fn ->
                 send(test_process, :ready_attempt)
                 {:error, :readiness_unavailable}
               end,
               fn -> flunk("stdin must not be read when readiness cannot be signaled") end,
               rpc,
               fn _target -> flunk("target must not be rechecked before stdin") end
             )

    assert_receive {:rpc, {:begin, :ios, :cold}}
    assert_receive :ready_attempt
    assert_receive {:rpc, {:finish, :opaque_fence, [], :ios, :cold}}
    refute_receive _unexpected
  end

  test "malformed stdin retires the fence with an invalid non-consuming finish" do
    target = %{node: :target}
    test_process = self()

    rpc = fn ^target, command ->
      send(test_process, {:rpc, command})

      case command do
        {:begin, :android, :reconnect} ->
          {:ok, :opaque_fence}

        {:finish, :opaque_fence, [], :android, :reconnect} ->
          {:error, :invalid_request}
      end
    end

    assert {:error, :collection_failed} =
             FeedTimingSoakBridge.collect_for(
               target,
               :android,
               :reconnect,
               fn -> :ok end,
               fn -> {:error, :invalid_request} end,
               rpc,
               fn _target -> flunk("target must not be rechecked after rejected stdin") end
             )

    assert_receive {:rpc, {:begin, :android, :reconnect}}
    assert_receive {:rpc, {:finish, :opaque_fence, [], :android, :reconnect}}
    refute_receive _unexpected
  end

  test "a target change fails closed, never fails over, and retires only the original fence" do
    target = %{node: :original}
    generations = generations(201..220)
    test_process = self()

    rpc = fn observed_target, command ->
      send(test_process, {:rpc, observed_target, command})

      case command do
        {:begin, :ios, :origin_switch} ->
          {:ok, :opaque_fence}

        {:finish, :opaque_fence, [], :ios, :origin_switch} ->
          {:error, :invalid_request}
      end
    end

    assert {:error, :collection_failed} =
             FeedTimingSoakBridge.collect_for(
               target,
               :ios,
               :origin_switch,
               fn -> :ok end,
               fn -> {:ok, generations} end,
               rpc,
               fn ^target -> {:error, :invalid_target} end
             )

    assert_receive {:rpc, ^target, {:begin, :ios, :origin_switch}}
    assert_receive {:rpc, ^target, {:finish, :opaque_fence, [], :ios, :origin_switch}}
    refute_receive _unexpected
  end

  test "a begin failure reads no stdin and makes no follow-up call" do
    target = %{node: :target}
    test_process = self()

    assert {:error, :collection_failed} =
             FeedTimingSoakBridge.collect_for(
               target,
               :ios,
               :cold,
               fn -> flunk("ready must not be signaled before a successful begin") end,
               fn -> flunk("stdin must not be read before a successful begin") end,
               fn ^target, command ->
                 send(test_process, {:rpc, command})
                 {:error, :rpc_failed}
               end,
               fn _target -> flunk("target must not be rechecked after begin failure") end
             )

    assert_receive {:rpc, {:begin, :ios, :cold}}
    refute_receive _unexpected
  end

  test "a failed finish is never retried because its consuming result is uncertain" do
    target = %{node: :target}
    generations = generations(301..320)
    test_process = self()

    rpc = fn ^target, command ->
      send(test_process, {:rpc, command})

      case command do
        {:begin, :android, :cold} -> {:ok, :opaque_fence}
        {:finish, :opaque_fence, ^generations, :android, :cold} -> {:error, :rpc_failed}
      end
    end

    assert {:error, :collection_failed} =
             FeedTimingSoakBridge.collect_for(
               target,
               :android,
               :cold,
               fn -> :ok end,
               fn -> {:ok, generations} end,
               rpc,
               fn ^target ->
                 send(test_process, :recheck)
                 :ok
               end
             )

    assert_receive {:rpc, {:begin, :android, :cold}}
    assert_receive :recheck
    assert_receive {:rpc, {:finish, :opaque_fence, ^generations, :android, :cold}}
    refute_receive _unexpected
  end

  test "a post-finish target change fails closed without replaying finish" do
    target = %{node: :target}
    generations = generations(321..340)
    aggregate = %{"component" => "server"}
    test_process = self()

    rpc = fn ^target, command ->
      send(test_process, {:rpc, command})

      case command do
        {:begin, :ios, :reconnect} -> {:ok, :opaque_fence}
        {:finish, :opaque_fence, ^generations, :ios, :reconnect} -> {:ok, aggregate}
      end
    end

    recheck = fn ^target ->
      invocation = Process.get(:soak_bridge_recheck_invocation, 0)
      Process.put(:soak_bridge_recheck_invocation, invocation + 1)
      send(test_process, {:recheck, invocation})
      if invocation == 0, do: :ok, else: {:error, :invalid_target}
    end

    assert {:error, :collection_failed} =
             FeedTimingSoakBridge.collect_for(
               target,
               :ios,
               :reconnect,
               fn -> :ok end,
               fn -> {:ok, generations} end,
               rpc,
               recheck
             )

    assert_receive {:rpc, {:begin, :ios, :reconnect}}
    assert_receive {:recheck, 0}
    assert_receive {:rpc, {:finish, :opaque_fence, ^generations, :ios, :reconnect}}
    assert_receive {:recheck, 1}
    refute_receive _unexpected
  end

  defp generations(range), do: Enum.map(range, &generation/1)

  defp aggregate_fixture do
    empty_summary = %{"min" => nil, "p50" => nil, "p95" => nil, "max" => nil}

    %{
      "schema_version" => 1,
      "component" => "server",
      "platform" => "ios",
      "cycle" => "cold",
      "expected_generation_count" => 20,
      "observed_generation_count" => 0,
      "cohort_match" => false,
      "stage_timings" =>
        Map.new(@stages, fn stage ->
          {stage,
           %{
             "sample_count" => 0,
             "duration_ms" => empty_summary,
             "elapsed_ms" => empty_summary
           }}
        end),
      "outcome_counts" => Map.new(@outcomes, &{&1, 0}),
      "reason_counts" => Map.new(@reasons, &{&1, 0}),
      "optional_measurements" => %{}
    }
  end

  defp aggregate_with_records(aggregate, count, cohort_match)
       when is_integer(count) and count > 0 and is_boolean(cohort_match) do
    p95 = if count >= 10, do: 4, else: nil
    summary = %{"min" => 1, "p50" => 2, "p95" => p95, "max" => 5}

    aggregate
    |> Map.put("observed_generation_count", if(cohort_match, do: 20, else: min(count, 20)))
    |> Map.put("cohort_match", cohort_match)
    |> put_in(["stage_timings", "token_verified", "sample_count"], count)
    |> put_in(["stage_timings", "token_verified", "duration_ms"], summary)
    |> put_in(["stage_timings", "token_verified", "elapsed_ms"], summary)
    |> put_in(["outcome_counts", "succeeded"], count)
    |> put_in(["reason_counts", "none"], count)
  end

  defp generation(index) do
    :sha256
    |> :crypto.hash("casein-soak-bridge-#{index}")
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
