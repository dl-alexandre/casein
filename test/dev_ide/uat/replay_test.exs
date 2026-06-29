defmodule DevIDE.UAT.ReplayTest do
  use DevIde.DataCase, async: false

  alias DevIDE.PreviewControl.Registry
  alias DevIDE.UAT.{Replay, Run, Step, Trace}

  @workspace %{
    id: "ws-preview",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100, "tidewave" => 11_003}
    }
  }

  setup do
    _ = Registry.clear()
    :ok
  end

  defp trace(id, criterion, steps) do
    %Trace{id: id, criterion: criterion, target: %{"surface" => "app"}, steps: steps}
  end

  test "a fully resolvable trace replays to :pass and persists a run" do
    t =
      trace("happy", "user can submit the search form", [
        %Step{kind: :navigate, path: "/login"},
        %Step{
          kind: :assert_element,
          match: %{"selector" => "button[type=submit]"},
          presence: true
        },
        %Step{kind: :type, match: %{"selector" => "input[name=q]"}, text: "hello"},
        %Step{kind: :click, match: %{"selector" => "button[type=submit]"}},
        %Step{kind: :assert_url, matches: "example.com"},
        %Step{kind: :assert_no_errors, console: true, network: true}
      ])

    assert {:ok, %Run{} = run} = Replay.run(t, @workspace)
    assert run.outcome == :pass
    assert run.scenario_id == "happy"
    assert run.tier == :tier_a
    assert is_integer(run.session_id)
    assert run.verdict["outcome"] == "pass"
    assert length(run.verdict["steps"]) == 6

    assert Repo.get(Run, run.id)
  end

  test "an unresolvable action target yields :drift and halts before later steps" do
    t =
      trace("drift", "click a button that no longer exists", [
        %Step{kind: :navigate, path: "/"},
        %Step{kind: :click, match: %{"selector" => "button[name=ghost]"}},
        %Step{kind: :assert_url, matches: "SHOULD-NOT-RUN"}
      ])

    assert {:ok, %Run{outcome: :drift} = run} = Replay.run(t, @workspace)
    # navigate (ok) + click (drift); the trailing assertion never executed.
    assert [%{"status" => "ok"}, %{"status" => "drift"}] = run.verdict["steps"]
  end

  test "a failed assertion yields :fail without halting" do
    t =
      trace("fail", "expect an element that is absent", [
        %Step{kind: :navigate, path: "/"},
        %Step{kind: :assert_element, match: %{"selector" => "#nope"}, presence: true},
        %Step{kind: :assert_url, matches: "example.com"}
      ])

    assert {:ok, %Run{outcome: :fail} = run} = Replay.run(t, @workspace)
    # All three steps ran; the middle assertion failed.
    assert [%{"status" => "ok"}, %{"status" => "fail"}, %{"status" => "pass"}] =
             run.verdict["steps"]
  end

  test "an absence assertion passes when the element is genuinely gone" do
    t =
      trace("absent", "a removed element should be absent", [
        %Step{kind: :navigate, path: "/"},
        %Step{kind: :assert_element, match: %{"selector" => "#nope"}, presence: false}
      ])

    assert {:ok, %Run{outcome: :pass}} = Replay.run(t, @workspace)
  end

  test "an observed :fail outranks a later :drift (regression is not self-healed)" do
    t =
      trace("fail-then-drift", "a real failure before a drift must report :fail", [
        %Step{kind: :navigate, path: "/"},
        # assertion fails (element absent) but does not halt...
        %Step{kind: :assert_element, match: %{"selector" => "#nope"}, presence: true},
        # ...then an action target drifts and halts.
        %Step{kind: :click, match: %{"selector" => "button[name=ghost]"}}
      ])

    assert {:ok, %Run{outcome: :fail} = run} = Replay.run(t, @workspace)
    assert [_, %{"status" => "fail"}, %{"status" => "drift"}] = run.verdict["steps"]
  end

  test "assert_screenshot is skipped by default and never affects the outcome" do
    t =
      trace("vis-off", "visual tier is opt-in", [
        %Step{kind: :navigate, path: "/"},
        %Step{kind: :assert_screenshot, baseline: "priv/uat/checkout/baselines/x.png"}
      ])

    assert {:ok, %Run{outcome: :pass} = run} = Replay.run(t, @workspace)
    assert [_, %{"status" => "skipped"}] = run.verdict["steps"]
  end

  test "assert_screenshot mismatch is advisory (:warn) — outcome stays :pass" do
    t =
      trace("vis-on", "visual mismatch never gates", [
        %Step{kind: :navigate, path: "/"},
        %Step{kind: :assert_screenshot, baseline: "/no/such/baseline.png"}
      ])

    # Enabled, but the baseline/actual won't resolve → advisory :warn, not :fail.
    assert {:ok, %Run{outcome: :pass} = run} = Replay.run(t, @workspace, visual: true)
    assert [_, %{"status" => "warn"}] = run.verdict["steps"]
  end
end
