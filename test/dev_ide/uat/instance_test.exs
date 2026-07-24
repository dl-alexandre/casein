defmodule Casein.UAT.InstanceTest do
  use Casein.TestCase, async: false

  alias Casein.UAT.{FakeRunner, Instance, Manifest}

  setup do
    FakeRunner.set_probe(:ok)
    :ok
  end

  defp manifest(overrides \\ %{}) do
    Manifest.from_map(
      Map.merge(
        %{"scenario_id" => "demo", "seed_cmd" => "echo seed", "tiers" => ["tier_a"]},
        overrides
      )
    )
  end

  test "boots with a fixed port and a staged temp root, then tears down by PID" do
    {:ok, inst} = Instance.boot(manifest(), runner: FakeRunner, port: 41_049)

    assert inst.port == 41_049
    assert inst.base_url == "http://127.0.0.1:41049"
    assert inst.handle == %{os_pid: 4242}
    assert inst.owns_root
    assert File.dir?(inst.workspaces_root)

    assert %{port: 41_049, workspaces_root: root, env: env} = FakeRunner.launched()
    assert env["CASEIN_WORKSPACES_ROOT"] == root
    assert env["PORT"] == "41049"
    assert {"echo seed", ^root} = FakeRunner.seeded()

    assert :ok = Instance.teardown(inst)
    # Killed the exact launched PID — never a broad pattern.
    assert FakeRunner.killed() == [%{os_pid: 4242}]
    refute File.exists?(root)
  end

  test "an unready instance fails boot, kills the half-start, and removes the temp root" do
    FakeRunner.set_probe({:error, :econnrefused})

    assert {:error, {:not_ready, :econnrefused}} =
             Instance.boot(manifest(),
               runner: FakeRunner,
               port: 41_048,
               probe_retries: 1,
               probe_delay_ms: 0
             )

    assert FakeRunner.killed() == [%{os_pid: 4242}]
    %{workspaces_root: root} = FakeRunner.launched()
    refute File.exists?(root)
  end

  test "skips seeding when no seed_cmd and stages fixtures from scenario_dir" do
    scenario_dir = Path.join(System.tmp_dir!(), "uat-scn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scenario_dir, "fixtures"))
    File.write!(Path.join(scenario_dir, "fixtures/seed.txt"), "hi")

    m = manifest(%{"seed_cmd" => nil, "tiers" => ["tier_b"], "fixtures_dir" => "fixtures"})
    {:ok, inst} = Instance.boot(m, runner: FakeRunner, port: 41_047, scenario_dir: scenario_dir)

    staged = Path.wildcard(Path.join(inst.workspaces_root, "**/seed.txt"))
    assert staged != []
    assert File.read!(hd(staged)) == "hi"
    assert FakeRunner.seeded() == nil

    Instance.teardown(inst)
    File.rm_rf(scenario_dir)
  end
end
