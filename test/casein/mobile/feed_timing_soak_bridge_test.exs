defmodule Casein.Mobile.FeedTimingSoakBridgeTest do
  use ExUnit.Case, async: true

  alias Casein.Mobile.FeedTimingSoakBridge

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

    leaking_id = put_in(aggregate["stage_timings"], %{"unsafe" => hd(generations)})
    leaking_cookie = put_in(aggregate["reason_counts"], %{"unsafe" => cookie})

    for rejected <- [
          leaking_id,
          leaking_cookie,
          %{aggregate | "platform" => "android"},
          %{aggregate | "cycle" => "reconnect"},
          Map.put(aggregate, "unexpected", true)
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
    %{
      "schema_version" => 1,
      "component" => "server",
      "platform" => "ios",
      "cycle" => "cold",
      "expected_generation_count" => 20,
      "observed_generation_count" => 20,
      "cohort_match" => true,
      "stage_timings" => %{},
      "outcome_counts" => %{},
      "reason_counts" => %{},
      "optional_measurements" => %{}
    }
  end

  defp generation(index) do
    :sha256
    |> :crypto.hash("casein-soak-bridge-#{index}")
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
