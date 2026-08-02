defmodule Casein.Mobile.FeedTimingSoakBridge do
  @moduledoc """
  Release-only bridge for one privacy-safe physical feed-timing cohort.

  The bridge is deliberately not exposed over HTTP. A local, hidden Erlang
  client discovers the single instance selected by `current.sock`, opens a
  recorder fence before reading stdin, emits one fixed readiness control line,
  and returns only the fixed aggregate on stdout.
  """

  alias Casein.Mobile.{FeedTiming, FeedTimingRecorder}

  @current_socket "/run/casein/current.sock"
  @instances_root "/run/casein/instances"
  @credential_file "/etc/casein/casein.env"
  @credential_file_max_bytes 65_536
  @minimum_cookie_bytes 32
  @maximum_cookie_bytes 128
  @generation_count 20
  @generation_line_bytes 23
  @stdin_max_bytes @generation_count * @generation_line_bytes + 1
  @rpc_timeout 5_000
  @ready_fd_path "/dev/fd/3"
  @ready_line "CASEIN_MOBILE_FEED_SOAK_READY\n"
  @unix_file_type_mask 0o170000
  @unix_socket_mode 0o140000

  @platforms %{"ios" => :ios, "android" => :android}
  @cycles %{
    "cold" => :cold,
    "reconnect" => :reconnect,
    "origin_switch" => :origin_switch
  }

  @aggregate_keys MapSet.new([
                    "schema_version",
                    "component",
                    "platform",
                    "cycle",
                    "expected_generation_count",
                    "observed_generation_count",
                    "cohort_match",
                    "stage_timings",
                    "outcome_counts",
                    "reason_counts",
                    "optional_measurements"
                  ])

  @stage_names MapSet.new(~w(
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
               ))
  @outcome_names MapSet.new(~w(started succeeded failed skipped))
  @reason_names MapSet.new(~w(
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
                ))
  @optional_measurement_names MapSet.new(~w(card_count snapshot_json_bytes))
  @stage_timing_keys MapSet.new(~w(sample_count duration_ms elapsed_ms))
  @summary_keys MapSet.new(~w(min p50 p95 max))
  @optional_summary_keys MapSet.new(~w(sample_count min p50 p95 max))
  @maximum_aggregate_records 2_000
  @maximum_duration_ms 86_400_000
  @maximum_card_count 1_000
  @maximum_snapshot_json_bytes 1_000_000
  @maximum_encoded_aggregate_bytes 65_536

  @failure_exit_status 74

  @doc """
  Constant release-eval entrypoint.

  Only fixed, non-secret platform/cycle arguments are accepted. All failures
  halt without reflecting input; the release overlay owns the single fixed
  stderr error code.
  """
  @spec run() :: :ok | no_return()
  def run do
    result =
      with {:ok, platform, cycle} <- parse_scope(System.argv()),
           {:ok, target} <- discover_target(),
           {:ok, cookie} <- read_cookie_file(),
           :ok <- start_hidden_client(cookie),
           {:ok, aggregate, generations} <-
             collect_for(
               target,
               platform,
               cycle,
               &signal_ready/0,
               &read_generations/0,
               &remote_call/2,
               &recheck_target/1
             ),
           {:ok, encoded} <-
             encode_aggregate(aggregate, generations, cookie, platform, cycle) do
        IO.binwrite(:stdio, [encoded, "\n"])
      end

    case result do
      :ok -> :ok
      _failure -> System.halt(@failure_exit_status)
    end
  rescue
    _failure -> System.halt(@failure_exit_status)
  catch
    _kind, _reason -> System.halt(@failure_exit_status)
  end

  @doc false
  @spec rpc(term()) :: {:ok, term()} | {:error, :invalid_request}
  def rpc({:begin, platform, cycle}) do
    FeedTimingRecorder.begin_cohort(platform, cycle)
  end

  def rpc({:finish, fence, generations, platform, cycle}) do
    FeedTimingRecorder.finish_cohort(fence, generations, platform, cycle)
  end

  def rpc(_invalid), do: {:error, :invalid_request}

  @doc false
  @spec parse_scope(term()) ::
          {:ok, :ios | :android, :cold | :reconnect | :origin_switch}
          | {:error, :invalid_request}
  def parse_scope([platform, cycle]) when is_binary(platform) and is_binary(cycle) do
    with {:ok, platform} <- Map.fetch(@platforms, platform),
         {:ok, cycle} <- Map.fetch(@cycles, cycle) do
      {:ok, platform, cycle}
    else
      :error -> {:error, :invalid_request}
    end
  end

  def parse_scope(_args), do: {:error, :invalid_request}

  @doc false
  @spec ready_line() :: String.t()
  def ready_line, do: @ready_line

  @doc false
  @spec parse_cookie(term()) :: {:ok, String.t()} | {:error, :invalid_credential}
  def parse_cookie(contents)
      when is_binary(contents) and byte_size(contents) <= @credential_file_max_bytes do
    if :binary.match(contents, "\r") == :nomatch and
         :binary.match(contents, <<0>>) == :nomatch do
      contents
      |> :binary.split("\n", [:global])
      |> Enum.reduce_while([], fn
        <<"RELEASE_COOKIE=", value::binary>>, matches ->
          {:cont, [value | matches]}

        _other_line, matches ->
          {:cont, matches}
      end)
      |> case do
        [cookie] -> validate_cookie(cookie)
        _missing_or_duplicate -> {:error, :invalid_credential}
      end
    else
      {:error, :invalid_credential}
    end
  end

  def parse_cookie(_contents), do: {:error, :invalid_credential}

  @doc false
  @spec parse_generations(term()) :: {:ok, [String.t()]} | {:error, :invalid_request}
  def parse_generations(contents)
      when is_binary(contents) and
             byte_size(contents) == @generation_count * @generation_line_bytes do
    with :nomatch <- :binary.match(contents, "\r"),
         :nomatch <- :binary.match(contents, <<0>>),
         parts <- :binary.split(contents, "\n", [:global]),
         {generations, [""]} <- Enum.split(parts, @generation_count),
         true <- length(generations) == @generation_count,
         true <- Enum.all?(generations, &FeedTiming.generation_valid?/1),
         true <- MapSet.size(MapSet.new(generations)) == @generation_count do
      {:ok, generations}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  def parse_generations(_contents), do: {:error, :invalid_request}

  @doc false
  @spec target_from_link(term(), term()) :: {:ok, map()} | {:error, :invalid_target}
  def target_from_link(link_target, hostname)
      when is_binary(link_target) and is_binary(hostname) do
    escaped_root = Regex.escape(@instances_root)

    with [uuid] <-
           Regex.run(~r/\A#{escaped_root}\/([0-9a-f]{16})\.sock\z/, link_target,
             capture: :all_but_first
           ),
         true <- hostname_valid?(hostname) do
      node_name = "casein_#{uuid}@#{hostname}"

      # The current-socket link value is constrained to one 16-hex instance
      # name. The target itself must lstat as a socket, never an indirection.
      # Keep the derived node as bounded data until the private release-only
      # RPC path converts it inside the short-lived no-listen client VM.
      {:ok, %{socket_path: link_target, instance_id: uuid, node_name: node_name}}
    else
      _invalid -> {:error, :invalid_target}
    end
  end

  def target_from_link(_link_target, _hostname), do: {:error, :invalid_target}

  @doc false
  @spec collect_for(
          map(),
          :ios | :android,
          :cold | :reconnect | :origin_switch,
          (-> :ok | {:error, term()}),
          (-> {:ok, [String.t()]} | {:error, term()}),
          (map(), term() -> {:ok, term()} | {:error, term()}),
          (map() -> :ok | {:error, term()})
        ) :: {:ok, map(), [String.t()]} | {:error, :collection_failed}
  def collect_for(target, platform, cycle, ready_fun, reader, rpc_fun, recheck_fun)
      when is_function(ready_fun, 0) and is_function(reader, 0) and is_function(rpc_fun, 2) and
             is_function(recheck_fun, 1) do
    case call2(rpc_fun, target, {:begin, platform, cycle}) do
      {:callback_ok, {:ok, fence}} ->
        case call0(ready_fun) do
          {:callback_ok, :ok} ->
            finish_collection(
              target,
              fence,
              platform,
              cycle,
              reader,
              rpc_fun,
              recheck_fun
            )

          _ready_failed ->
            retire_fence(rpc_fun, target, fence, platform, cycle)
            {:error, :collection_failed}
        end

      _begin_failed ->
        {:error, :collection_failed}
    end
  rescue
    _failure -> {:error, :collection_failed}
  catch
    _kind, _reason -> {:error, :collection_failed}
  end

  defp finish_collection(target, fence, platform, cycle, reader, rpc_fun, recheck_fun) do
    case call0(reader) do
      {:callback_ok, {:ok, generations}} ->
        case call1(recheck_fun, target) do
          {:callback_ok, :ok} ->
            finish_rechecked_collection(
              target,
              fence,
              generations,
              platform,
              cycle,
              rpc_fun,
              recheck_fun
            )

          _target_changed ->
            retire_fence(rpc_fun, target, fence, platform, cycle)
            {:error, :collection_failed}
        end

      _input_failed ->
        retire_fence(rpc_fun, target, fence, platform, cycle)
        {:error, :collection_failed}
    end
  end

  defp finish_rechecked_collection(
         target,
         fence,
         generations,
         platform,
         cycle,
         rpc_fun,
         recheck_fun
       ) do
    case call2(rpc_fun, target, {:finish, fence, generations, platform, cycle}) do
      {:callback_ok, {:ok, aggregate}} ->
        case call1(recheck_fun, target) do
          {:callback_ok, :ok} -> {:ok, aggregate, generations}
          _target_changed -> {:error, :collection_failed}
        end

      _finish_failed ->
        # Finish is single-use even when the reply is invalid or transport is
        # uncertain. Never retry a potentially completed consuming operation.
        {:error, :collection_failed}
    end
  end

  defp retire_fence(rpc_fun, target, fence, platform, cycle) do
    # An empty generation list cannot consume rows, but it does retire the
    # single-use recorder fence after malformed or interrupted stdin.
    _ = call2(rpc_fun, target, {:finish, fence, [], platform, cycle})
    :ok
  rescue
    _failure -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp discover_target do
    with {:ok, %{type: :symlink}} <- File.lstat(@current_socket),
         {:ok, link_target} <- File.read_link(@current_socket),
         {:ok, target_stat} <- File.lstat(link_target),
         true <- socket_target_stat_valid?(target_stat),
         {:ok, hostname} <- :inet.gethostname(),
         {:ok, target} <- target_from_link(link_target, List.to_string(hostname)) do
      {:ok, target}
    else
      _failure -> {:error, :invalid_target}
    end
  end

  defp recheck_target(expected_target) do
    case discover_target() do
      {:ok, ^expected_target} -> :ok
      _changed_or_invalid -> {:error, :invalid_target}
    end
  end

  @doc false
  @spec socket_target_stat_valid?(term()) :: boolean()
  def socket_target_stat_valid?(%File.Stat{type: :other, mode: mode}) when is_integer(mode) do
    Bitwise.band(mode, @unix_file_type_mask) == @unix_socket_mode
  end

  def socket_target_stat_valid?(_stat), do: false

  defp read_cookie_file do
    with {:ok, stat} <- File.lstat(@credential_file),
         true <- private_credential_stat?(stat),
         true <- stat.size <= @credential_file_max_bytes,
         {:ok, contents} <- File.read(@credential_file) do
      parse_cookie(contents)
    else
      _failure -> {:error, :invalid_credential}
    end
  end

  @doc false
  @spec private_credential_stat?(term()) :: boolean()
  def private_credential_stat?(%File.Stat{type: :regular, links: 1, mode: mode})
      when is_integer(mode) do
    Bitwise.band(mode, 0o077) == 0
  end

  def private_credential_stat?(_stat), do: false

  defp signal_ready do
    case File.open(@ready_fd_path, [:append, :binary], fn device ->
           IO.binwrite(device, @ready_line)
         end) do
      {:ok, :ok} -> :ok
      _unavailable -> {:error, :readiness_unavailable}
    end
  rescue
    _failure -> {:error, :readiness_unavailable}
  catch
    _kind, _reason -> {:error, :readiness_unavailable}
  end

  defp validate_cookie(cookie)
       when byte_size(cookie) >= @minimum_cookie_bytes and
              byte_size(cookie) <= @maximum_cookie_bytes do
    if cookie_bytes_valid?(cookie),
      do: {:ok, cookie},
      else: {:error, :invalid_credential}
  end

  defp validate_cookie(_cookie), do: {:error, :invalid_credential}

  defp cookie_bytes_valid?(<<>>), do: true

  defp cookie_bytes_valid?(<<byte, rest::binary>>)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?-],
       do: cookie_bytes_valid?(rest)

  defp cookie_bytes_valid?(_invalid), do: false

  defp hostname_valid?(hostname) when byte_size(hostname) in 1..63 do
    hostname
    |> :binary.bin_to_list()
    |> hostname_bytes_valid?()
  end

  defp hostname_valid?(_hostname), do: false

  defp hostname_bytes_valid?([first | _rest] = bytes)
       when first in ?A..?Z or first in ?a..?z or first in ?0..?9 do
    last = List.last(bytes)

    (last in ?A..?Z or last in ?a..?z or last in ?0..?9) and
      Enum.all?(bytes, fn byte ->
        byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte == ?-
      end)
  end

  defp hostname_bytes_valid?(_bytes), do: false

  # Both atoms are bounded and live only for this release helper's short VM:
  # the suffix is fixed-width random data and the cookie passed strict parsing.
  # sobelow_skip ["DOS.BinToAtom"]
  defp start_hidden_client(cookie) do
    suffix =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    client_name = :erlang.binary_to_atom("casein_feed_soak_#{suffix}", :utf8)
    cookie_atom = :erlang.binary_to_atom(cookie, :utf8)

    with {:ok, _pid} <-
           :net_kernel.start([
             client_name,
             :shortnames,
             %{hidden: true, dist_listen: false}
           ]),
         true <- Node.set_cookie(cookie_atom) do
      :ok
    else
      _failure -> {:error, :client_start_failed}
    end
  rescue
    _failure -> {:error, :client_start_failed}
  catch
    _kind, _reason -> {:error, :client_start_failed}
  end

  defp read_generations do
    case IO.binread(:stdio, @stdin_max_bytes) do
      contents when is_binary(contents) -> parse_generations(contents)
      _eof_or_error -> {:error, :invalid_request}
    end
  end

  # node_name came from the canonical 16-hex socket plus a bounded hostname;
  # this conversion lives only in the short-lived release helper VM.
  # sobelow_skip ["DOS.BinToAtom"]
  defp remote_call(%{node_name: node_name}, command) when is_binary(node_name) do
    target_node = :erlang.binary_to_atom(node_name, :utf8)

    case :erpc.call(target_node, __MODULE__, :rpc, [command], @rpc_timeout) do
      {:ok, _value} = ok -> ok
      _invalid_reply -> {:error, :rpc_failed}
    end
  rescue
    _failure -> {:error, :rpc_failed}
  catch
    _kind, _reason -> {:error, :rpc_failed}
  end

  defp call0(fun) do
    {:callback_ok, fun.()}
  rescue
    _failure -> :callback_error
  catch
    _kind, _reason -> :callback_error
  end

  defp call1(fun, value) do
    {:callback_ok, fun.(value)}
  rescue
    _failure -> :callback_error
  catch
    _kind, _reason -> :callback_error
  end

  defp call2(fun, first, second) do
    {:callback_ok, fun.(first, second)}
  rescue
    _failure -> :callback_error
  catch
    _kind, _reason -> :callback_error
  end

  @doc false
  @spec encode_aggregate(
          map(),
          [String.t()],
          String.t(),
          :ios | :android,
          :cold | :reconnect | :origin_switch
        ) :: {:ok, String.t()} | {:error, :invalid_aggregate}
  def encode_aggregate(aggregate, generations, cookie, platform, cycle)
      when is_map(aggregate) and is_list(generations) and is_binary(cookie) do
    with true <- aggregate_schema_valid?(aggregate),
         1 <- aggregate["schema_version"],
         "server" <- aggregate["component"],
         platform_name <- Atom.to_string(platform),
         ^platform_name <- aggregate["platform"],
         cycle_name <- Atom.to_string(cycle),
         ^cycle_name <- aggregate["cycle"],
         @generation_count <- aggregate["expected_generation_count"],
         true <- valid_generation_set?(generations),
         {:ok, encoded} <- Jason.encode(aggregate),
         true <- encoded_aggregate_size_valid?(encoded),
         false <- String.contains?(encoded, cookie),
         false <- Enum.any?(generations, &String.contains?(encoded, &1)) do
      {:ok, encoded}
    else
      _unsafe_or_invalid -> {:error, :invalid_aggregate}
    end
  end

  def encode_aggregate(_aggregate, _generations, _cookie, _platform, _cycle),
    do: {:error, :invalid_aggregate}

  @doc false
  @spec encoded_aggregate_size_valid?(term()) :: boolean()
  def encoded_aggregate_size_valid?(encoded) when is_binary(encoded),
    do: byte_size(encoded) <= @maximum_encoded_aggregate_bytes

  def encoded_aggregate_size_valid?(_encoded), do: false

  defp aggregate_schema_valid?(aggregate) do
    Enum.all?([
      exact_keys?(aggregate, @aggregate_keys),
      aggregate["schema_version"] == 1,
      aggregate["component"] == "server",
      aggregate["platform"] in ["ios", "android"],
      aggregate["cycle"] in ["cold", "reconnect", "origin_switch"],
      aggregate["expected_generation_count"] == @generation_count,
      bounded_count?(aggregate["observed_generation_count"]),
      is_boolean(aggregate["cohort_match"]),
      cohort_flag_consistent?(aggregate),
      stage_timings_valid?(aggregate["stage_timings"]),
      fixed_counts_valid?(aggregate["outcome_counts"], @outcome_names),
      fixed_counts_valid?(aggregate["reason_counts"], @reason_names),
      optional_measurements_valid?(aggregate["optional_measurements"]),
      cross_map_counts_valid?(aggregate)
    ])
  end

  defp exact_keys?(map, expected) when is_map(map) do
    MapSet.new(Map.keys(map)) == expected
  end

  defp exact_keys?(_map, _expected), do: false

  defp cohort_flag_consistent?(%{
         "cohort_match" => true,
         "observed_generation_count" => @generation_count
       }),
       do: true

  defp cohort_flag_consistent?(%{"cohort_match" => false}), do: true
  defp cohort_flag_consistent?(_aggregate), do: false

  defp stage_timings_valid?(stage_timings) do
    exact_keys?(stage_timings, @stage_names) and
      Enum.all?(stage_timings, fn {_stage, timing} -> stage_timing_valid?(timing) end)
  end

  defp stage_timing_valid?(timing) do
    exact_keys?(timing, @stage_timing_keys) and
      bounded_count?(timing["sample_count"]) and
      duration_summary_valid?(timing["duration_ms"], timing["sample_count"]) and
      duration_summary_valid?(timing["elapsed_ms"], timing["sample_count"])
  end

  defp duration_summary_valid?(summary, sample_count) do
    exact_keys?(summary, @summary_keys) and
      summary_values_valid?(
        summary,
        sample_count,
        &bounded_number?(&1, @maximum_duration_ms)
      )
  end

  defp fixed_counts_valid?(counts, expected_names) do
    exact_keys?(counts, expected_names) and
      Enum.all?(counts, fn {_name, count} -> bounded_count?(count) end)
  end

  defp optional_measurements_valid?(measurements) when is_map(measurements) do
    names = MapSet.new(Map.keys(measurements))

    MapSet.subset?(names, @optional_measurement_names) and
      Enum.all?(measurements, fn
        {"card_count", summary} ->
          optional_summary_valid?(summary, @maximum_card_count)

        {"snapshot_json_bytes", summary} ->
          optional_summary_valid?(summary, @maximum_snapshot_json_bytes)

        _unexpected ->
          false
      end)
  end

  defp optional_measurements_valid?(_measurements), do: false

  defp optional_summary_valid?(summary, maximum) do
    exact_keys?(summary, @optional_summary_keys) and
      positive_bounded_count?(summary["sample_count"]) and
      summary_values_valid?(summary, summary["sample_count"], fn value ->
        is_integer(value) and value >= 0 and value <= maximum
      end)
  end

  defp bounded_count?(count) do
    is_integer(count) and count >= 0 and count <= @maximum_aggregate_records
  end

  defp positive_bounded_count?(count), do: bounded_count?(count) and count > 0

  defp cross_map_counts_valid?(aggregate) do
    with {:ok, stage_total} <-
           aggregate_count_sum(aggregate["stage_timings"], &stage_sample_count/1),
         {:ok, outcome_total} <-
           aggregate_count_sum(aggregate["outcome_counts"], &fixed_count/1),
         {:ok, reason_total} <-
           aggregate_count_sum(aggregate["reason_counts"], &fixed_count/1),
         true <- stage_total == outcome_total,
         true <- outcome_total == reason_total,
         true <-
           optional_counts_within_total?(aggregate["optional_measurements"], stage_total),
         true <- cohort_record_count_valid?(aggregate["cohort_match"], stage_total) do
      true
    else
      _invalid_or_inconsistent -> false
    end
  end

  defp aggregate_count_sum(map, extractor) when is_map(map) and is_function(extractor, 1) do
    Enum.reduce_while(map, {:ok, 0}, fn {_key, value}, {:ok, total} ->
      count = extractor.(value)

      if bounded_count?(count) and total + count <= @maximum_aggregate_records do
        {:cont, {:ok, total + count}}
      else
        {:halt, :error}
      end
    end)
  end

  defp aggregate_count_sum(_map, _extractor), do: :error

  defp stage_sample_count(%{"sample_count" => count}), do: count
  defp stage_sample_count(_timing), do: :invalid
  defp fixed_count(count), do: count

  defp optional_counts_within_total?(measurements, total)
       when is_map(measurements) and is_integer(total) do
    Enum.all?(measurements, fn
      {_name, %{"sample_count" => sample_count}} ->
        bounded_count?(sample_count) and sample_count <= total

      _invalid_summary ->
        false
    end)
  end

  defp optional_counts_within_total?(_measurements, _total), do: false

  defp cohort_record_count_valid?(true, total), do: total >= @generation_count
  defp cohort_record_count_valid?(false, _total), do: true
  defp cohort_record_count_valid?(_cohort_match, _total), do: false

  defp bounded_number?(number, maximum) do
    is_number(number) and number >= 0 and number <= maximum
  end

  defp summary_values_valid?(summary, 0, _validator) do
    Enum.all?(~w(min p50 p95 max), &is_nil(summary[&1]))
  end

  defp summary_values_valid?(summary, sample_count, validator)
       when is_integer(sample_count) and sample_count > 0 and is_function(validator, 1) do
    minimum = summary["min"]
    p50 = summary["p50"]
    p95 = summary["p95"]
    maximum = summary["max"]

    Enum.all?([
      validator.(minimum),
      validator.(p50),
      validator.(maximum),
      p95_valid?(p95, sample_count, validator),
      summary_order_valid?(minimum, p50, p95, maximum)
    ])
  end

  defp summary_values_valid?(_summary, _sample_count, _validator), do: false

  defp p95_valid?(nil, sample_count, _validator) when sample_count < 10, do: true
  defp p95_valid?(value, sample_count, validator) when sample_count >= 10, do: validator.(value)
  defp p95_valid?(_value, _sample_count, _validator), do: false

  defp summary_order_valid?(minimum, p50, nil, maximum)
       when is_number(minimum) and is_number(p50) and is_number(maximum),
       do: minimum <= p50 and p50 <= maximum

  defp summary_order_valid?(minimum, p50, p95, maximum)
       when is_number(minimum) and is_number(p50) and is_number(p95) and is_number(maximum),
       do: minimum <= p50 and p50 <= p95 and p95 <= maximum

  defp summary_order_valid?(_minimum, _p50, _p95, _maximum), do: false

  defp valid_generation_set?(generations) do
    valid_generation_set?(generations, MapSet.new(), 0)
  end

  defp valid_generation_set?([], generations, @generation_count),
    do: MapSet.size(generations) == @generation_count

  defp valid_generation_set?([generation | rest], generations, count)
       when count < @generation_count and is_binary(generation) do
    if FeedTiming.generation_valid?(generation) and
         not MapSet.member?(generations, generation) do
      valid_generation_set?(rest, MapSet.put(generations, generation), count + 1)
    else
      false
    end
  end

  defp valid_generation_set?(_generations, _seen, _count), do: false
end
