defmodule Casein.Ops.PgProbeTest do
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Operator.SituationDigest
  alias Casein.Ops.PgProbe

  @app_env ~w(pg_probe pg_probe_targets pg_probe_targets_json pg_probe_interval_ms
              pg_probe_warn_utilization pg_probe_critical_utilization
              pg_probe_leak_suspects_max pg_probe_psql)a

  @sep <<0x1F>>

  setup do
    prev = Map.new(@app_env, &{&1, Application.get_env(:dev_ide, &1)})
    Audit.clear()

    on_exit(fn ->
      Audit.clear()

      Enum.each(prev, fn
        {key, nil} -> Application.delete_env(:dev_ide, key)
        {key, value} -> Application.put_env(:dev_ide, key, value)
      end)
    end)

    :ok
  end

  defp target(overrides \\ %{}) do
    Map.merge(%{host: "127.0.0.1", port: 5432, user: nil, dbname: nil, password: nil}, overrides)
  end

  defp sample(overrides \\ %{}) do
    Map.merge(
      %{
        host: "127.0.0.1",
        port: 5432,
        status: :ok,
        total: 10,
        max_connections: 400,
        utilization: 0.025,
        leak_suspects: [],
        leak_suspect_count: 0,
        checked_at: DateTime.utc_now()
      },
      overrides
    )
  end

  # Starts a probe server with no real targets and a dormant interval, so
  # tests inject {:pg_samples, ...} passes deterministically.
  defp start_probe do
    Application.put_env(:dev_ide, :pg_probe_targets, [])
    Application.put_env(:dev_ide, :pg_probe_interval_ms, 3_600_000)
    start_supervised!(PgProbe)
  end

  defp write_stub_psql(body) do
    dir = Path.join(System.tmp_dir!(), "pg-probe-stub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "psql")
    File.write!(path, "#!/usr/bin/env bash\n" <> body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end

  ## Output parsing + sample building (pure)

  test "parse_output reads per-app counts plus max_connections" do
    output = Enum.join(["app1#{@sep}12", "#{@sep}130", "psql#{@sep}1", "400"], "\n")

    assert {:ok, counts, 400} = PgProbe.parse_output(output)
    assert {"app1", 12} in counts
    assert {"", 130} in counts
    assert {"psql", 1} in counts
  end

  test "output without a max_connections line does not parse" do
    assert :error = PgProbe.parse_output("app#{@sep}3\n")
    assert :error = PgProbe.parse_output("FATAL: whatever\n")
  end

  test "build_sample computes utilization and both leak-suspect shapes" do
    output =
      Enum.join(
        [
          "wf_runner_1#{@sep}30",
          "devide-0f9c2ab1-3c1d-4e56-9b7a-1234567890ab#{@sep}20",
          "app#{@sep}50",
          "100"
        ],
        "\n"
      )

    assert %{status: :ok} = pg_sample = PgProbe.build_sample(target(), output)
    assert pg_sample.total == 100
    assert pg_sample.max_connections == 100
    assert pg_sample.utilization == 1.0
    assert pg_sample.leak_suspect_count == 50

    assert Enum.map(pg_sample.leak_suspects, & &1.application_name) ==
             ["wf_runner_1", "devide-0f9c2ab1-3c1d-4e56-9b7a-1234567890ab"]
  end

  test "non-leak application names are not suspects" do
    output = Enum.join(["phoenix#{@sep}9", "devide-viewer#{@sep}4", "200"], "\n")

    assert %{leak_suspects: [], leak_suspect_count: 0} = PgProbe.build_sample(target(), output)
  end

  test "unparseable output degrades to an unreachable sample" do
    assert %{status: :unreachable} = PgProbe.build_sample(target(), "FATAL: nope")
  end

  ## Threshold evaluation (pure)

  test "evaluate stays quiet below thresholds" do
    assert PgProbe.evaluate(sample()) == nil
  end

  test "evaluate warns at 70% and goes critical at 90% utilization" do
    assert %{severity: :warn, evidence: %{reasons: [:utilization_warn]}} =
             PgProbe.evaluate(sample(%{utilization: 0.75}))

    assert %{severity: :critical, evidence: %{reasons: [:utilization_critical]}} =
             PgProbe.evaluate(sample(%{utilization: 0.92}))
  end

  test "leak suspects above the max warn even at low utilization" do
    risk = PgProbe.evaluate(sample(%{leak_suspect_count: 11}))

    assert risk.severity == :warn
    assert risk.evidence.reasons == [:leak_suspects]
    assert risk.subject == "127.0.0.1:5432"
  end

  test "a too-many-clients refusal is the incident itself: critical" do
    unreachable =
      sample(%{
        status: :unreachable,
        error: "FATAL: sorry, too many clients already",
        exhausted: true
      })

    assert %{severity: :critical, evidence: %{reasons: [:exhausted]}} =
             PgProbe.evaluate(unreachable)
  end

  test "a plain unreachable target is sample-only signal, not a risk" do
    unreachable =
      sample(%{status: :unreachable, error: "password authentication failed", exhausted: false})

    assert PgProbe.evaluate(unreachable) == nil
  end

  ## psql shell-out (stubbed binary)

  test "probe_target parses a healthy psql run" do
    stub =
      write_stub_psql("""
      printf 'wf_leak\\x1f12\\n'
      printf 'app\\x1f3\\n'
      printf '400\\n'
      """)

    Application.put_env(:dev_ide, :pg_probe_psql, stub)

    assert %{status: :ok} = pg_sample = PgProbe.probe_target(target())
    assert pg_sample.total == 15
    assert pg_sample.max_connections == 400
    assert pg_sample.leak_suspect_count == 12
  end

  test "a failing psql yields an unreachable sample with redacted error text" do
    stub =
      write_stub_psql("""
      echo 'FATAL: sorry, too many clients already password=hunter2' >&2
      exit 1
      """)

    Application.put_env(:dev_ide, :pg_probe_psql, stub)

    assert %{status: :unreachable} = pg_sample = PgProbe.probe_target(target())
    assert pg_sample.exhausted
    assert pg_sample.error =~ "too many clients"
    assert pg_sample.error =~ "password=[REDACTED]"
    refute pg_sample.error =~ "hunter2"
  end

  test "a missing psql binary is an unreachable sample, not a crash" do
    Application.put_env(:dev_ide, :pg_probe_psql, "/nonexistent/psql")

    assert %{status: :unreachable} = PgProbe.probe_target(target())
  end

  ## Target configuration

  test "targets default to host and release Postgres" do
    Application.delete_env(:dev_ide, :pg_probe_targets)
    Application.delete_env(:dev_ide, :pg_probe_targets_json)

    assert [%{host: "127.0.0.1", port: 5432}, %{host: "127.0.0.1", port: 15_432}] =
             PgProbe.targets()
  end

  test "targets parse from JSON with per-target credentials" do
    Application.delete_env(:dev_ide, :pg_probe_targets)

    Application.put_env(
      :dev_ide,
      :pg_probe_targets_json,
      ~s([{"host":"10.0.0.9","port":"6432","user":"dev_ide","dbname":"dev_ide_prod"}])
    )

    assert [%{host: "10.0.0.9", port: 6432, user: "dev_ide", dbname: "dev_ide_prod"}] =
             PgProbe.targets()
  end

  test "invalid JSON falls back to the defaults" do
    Application.delete_env(:dev_ide, :pg_probe_targets)
    Application.put_env(:dev_ide, :pg_probe_targets_json, "{nope")

    assert [%{port: 5432}, %{port: 15_432}] = PgProbe.targets()
  end

  test "a non-numeric port falls back instead of crash-looping the probe" do
    Application.delete_env(:dev_ide, :pg_probe_targets)

    Application.put_env(
      :dev_ide,
      :pg_probe_targets_json,
      ~s([{"host":"127.0.0.1","port":"54O2"}])
    )

    assert [%{host: "127.0.0.1", port: 5432}] = PgProbe.targets()
  end

  ## Threshold transitions through the server

  test "transitions audit ops.pg_saturation_* and broadcast on ops:health" do
    pid = start_probe()
    :ok = PgProbe.subscribe()

    send(pid, {:pg_samples, [sample(%{utilization: 0.95})]})

    assert_receive {:ops_health, :pg_saturation, :raised, risk}, 2_000
    assert risk.severity == :critical
    assert risk.subject == "127.0.0.1:5432"
    assert [%{id: :pg_saturation}] = PgProbe.active_risks()
    assert [%{utilization: 0.95}] = PgProbe.current()

    raised = Enum.find(Audit.recent_for("_ops", 20), &(&1.action == "ops.pg_saturation_raised"))
    assert raised.actor_id == "pg_probe"
    assert raised.source == "ops"
    assert raised.target_type == "postgres"
    assert raised.target_ref == "127.0.0.1:5432"
    assert raised.metadata.severity == :critical

    # Steady state: the same breach is not a transition — no second raise.
    send(pid, {:pg_samples, [sample(%{utilization: 0.96})]})
    refute_receive {:ops_health, :pg_saturation, :raised, _risk}, 300

    send(pid, {:pg_samples, [sample(%{utilization: 0.1})]})

    assert_receive {:ops_health, :pg_saturation, :cleared, %{subject: "127.0.0.1:5432"}}, 2_000
    assert PgProbe.active_risks() == []

    assert Enum.any?(
             Audit.recent_for("_ops", 20),
             &(&1.action == "ops.pg_saturation_cleared")
           )
  end

  test "current and active_risks are whereis-safe without a probe" do
    assert PgProbe.current() == []
    assert PgProbe.active_risks() == []
    refute PgProbe.running?()
  end

  ## Digest ops section

  test "the digest gains an ops.pg section only while a probe runs" do
    assert {:ok, cold} = SituationDigest.build("ws-pg-ops")
    refute Map.has_key?(cold, :ops)

    pid = start_probe()
    send(pid, {:pg_samples, [sample()]})

    assert {:ok, digest} = SituationDigest.build("ws-pg-ops")
    assert [%{host: "127.0.0.1", port: 5432, status: :ok}] = digest.ops.pg
  end
end
