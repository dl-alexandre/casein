defmodule CaseinMob.AppTimingTest do
  use ExUnit.Case, async: false

  alias CaseinMob.App
  alias CaseinMob.ConnectionTiming
  alias CaseinMob.SessionConfig

  @pairing_env_names ~w(CASEIN_MOB_DEV_PAIRING_URL CASEIN_MOB_DEV_PAIRING_TOKEN)

  setup do
    previous_env = Map.new(@pairing_env_names, &{&1, System.get_env(&1)})

    if Process.whereis(Mob.State) == nil do
      start_supervised!(Mob.State)
    end

    SessionConfig.clear_all()
    ConnectionTiming.reset()
    Enum.each(@pairing_env_names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if Process.whereis(Mob.State), do: SessionConfig.clear_all()
      ConnectionTiming.reset()
    end)

    :ok
  end

  test "boot DNS resolution returns only bounded classifications" do
    assert App.resolve_session_hosts() == {:skip, :no_configuration}

    SessionConfig.put_pairing("https://127.0.0.1", "private-token")
    assert App.resolve_session_hosts() == {:skip, :ip_literal}

    SessionConfig.put_pairing("not-a-url", "private-token")
    assert App.resolve_session_hosts() == {:error, :invalid_url}

    SessionConfig.put_pairing("https://casein.example", "private-token")

    assert App.resolve_session_hosts(fn "casein.example" -> {:ok, {192, 0, 2, 1}} end) ==
             {:ok, :resolved}

    assert App.resolve_session_hosts(fn "casein.example" ->
             {:error, {:raw_resolver_detail, "must-not-appear"}}
           end) == {:error, :resolution_failed}

    assert App.resolve_session_hosts(fn "casein.example" ->
             raise "must-not-appear"
           end) == {:error, :resolution_failed}
  end

  test "boot DNS stage records truthful allowlisted outcomes without raw resolver detail" do
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

    [
      {{:ok, :resolved}, :succeeded, :dns_resolved},
      {{:skip, :ip_literal}, :skipped, :dns_ip_literal},
      {{:skip, :no_configuration}, :skipped, :no_configuration},
      {{:error, :invalid_url}, :failed, :dns_invalid_url},
      {{:error, {:raw, "must-not-appear"}}, :failed, :dns_resolution_failed}
    ]
    |> Enum.each(fn {result, expected_outcome, expected_reason} ->
      :ok =
        ConnectionTiming.boot_stage(
          :dns_ready,
          App.dns_timing_opts(result)
        )

      assert_receive {:connection_stage, measurements,
                      %{
                        stage: :dns_resolved,
                        outcome: ^expected_outcome,
                        reason_code: ^expected_reason
                      } = metadata}

      assert measurements.duration_ms >= 0
      assert measurements.elapsed_ms >= 0

      encoded = inspect({measurements, metadata})
      refute encoded =~ "must-not-appear"
      refute encoded =~ "private-token"
      refute encoded =~ "casein.example"
    end)
  end

  test "cold boot timing context can be atomically handed off only once" do
    ConnectionTiming.start_boot()
    generation = ConnectionTiming.boot_context().generation

    claimed_contexts =
      1..8
      |> Task.async_stream(
        fn _index -> ConnectionTiming.take_boot_context() end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, context} -> context end)
      |> Enum.reject(&is_nil/1)

    assert [%{generation: ^generation}] = claimed_contexts
    assert ConnectionTiming.boot_context() == nil
  end

  def handle_connection_stage(_event, measurements, metadata, pid) do
    send(pid, {:connection_stage, measurements, metadata})
  end
end
