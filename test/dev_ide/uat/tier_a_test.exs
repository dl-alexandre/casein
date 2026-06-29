defmodule DevIDE.UAT.TierATest do
  use DevIde.DataCase, async: false

  alias DevIDE.PreviewControl
  alias DevIDE.UAT.{FakeRunner, Manifest, Run, Step, TierA, Trace}

  @workspace %{
    id: "ws-preview",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    _ = PreviewControl.Registry.clear()
    FakeRunner.set_probe(:ok)
    :ok
  end

  # A trace built from the :memory adapter's default selectors so replay is
  # deterministic without a real app.
  defp memory_trace do
    %Trace{
      id: "demo",
      criterion: "the submit button is present and the page is clean",
      target: %{"surface" => "app"},
      steps: [
        %Step{kind: :navigate, path: "/"},
        %Step{
          kind: :assert_element,
          match: %{"selector" => "button[type=submit]"},
          presence: true
        },
        %Step{kind: :assert_no_errors, console: true, network: true}
      ]
    }
  end

  test "a tier_a-eligible scenario boots, replays to :pass, and tears the instance down" do
    m =
      Manifest.from_map(%{
        "scenario_id" => "demo",
        "seed_cmd" => "echo seed",
        "tiers" => ["tier_a"]
      })

    assert {:ok, %Run{outcome: :pass, tier: :tier_a}} =
             TierA.run_scenario(m, memory_trace(), @workspace,
               runner: FakeRunner,
               port: 41_096,
               workspaces_root: "/tmp/uat-noop-root"
             )

    assert FakeRunner.killed() == [%{os_pid: 4242}]
  end

  test "a tier_b-only scenario is skipped without booting" do
    m = Manifest.from_map(%{"scenario_id" => "demo", "tiers" => ["tier_b"]})

    assert {:skipped, :tier_b_only} =
             TierA.run_scenario(m, memory_trace(), @workspace, runner: FakeRunner)

    assert FakeRunner.launched() == nil
  end

  test "exit_code maps a batch of outcomes for the CI hook" do
    assert TierA.exit_code([{"a", {:ok, %{outcome: :pass}}}, {"b", {:skipped, :x}}]) == 0

    assert TierA.exit_code([{"a", {:ok, %{outcome: :fail}}}, {"b", {:ok, %{outcome: :drift}}}]) ==
             1

    assert TierA.exit_code([{"a", {:ok, %{outcome: :drift}}}]) == 2
    assert TierA.exit_code([{"a", {:error, :boom}}]) == 3
    assert TierA.exit_code([{"a", {:ok, %{outcome: :errored}}}]) == 3
  end

  test "scenario_dirs discovers committed scenarios under priv/uat" do
    root = Application.app_dir(:dev_ide, "priv/uat")
    dirs = TierA.scenario_dirs(root)
    assert Enum.any?(dirs, &(Path.basename(&1) == "checkout"))
  end
end
