defmodule DevIDE.UAT.TraceTest do
  use ExUnit.Case, async: true

  alias DevIDE.UAT.{Step, Trace}

  # JSON-native fixture (string values for free-form maps) so the round-trip is
  # stable — that is exactly what gets loaded from priv/uat/<scenario>/trace.json.
  defp sample_trace do
    %Trace{
      id: "checkout-saved-card",
      criterion: "A user can check out with a saved card and reach confirmation.",
      target: %{"surface" => "app", "path" => "/cart"},
      identity: "workspace_owner",
      provenance: %{
        "authored_by_run" => "uat_run_1",
        "authored_by_session" => "ctl_sess_9",
        "source_app_revision" => "abc123"
      },
      steps: [
        %Step{kind: :navigate, path: "/cart"},
        %Step{
          kind: :click,
          match: %{
            "selector" => "button[name=checkout]",
            "role" => "button",
            "name" => "Checkout"
          },
          from: %{"action_id" => 4411, "observation_id" => 9120, "resolved_el" => "el_3"}
        },
        %Step{kind: :type, match: %{"selector" => "#email"}, text: "uat@example.com"},
        %Step{kind: :press, key: "Enter"},
        %Step{
          kind: :assert_element,
          match: %{"role" => "button", "name" => "Pay"},
          presence: true
        },
        %Step{kind: :assert_url, matches: "/confirmation"},
        %Step{kind: :assert_no_errors, console: true, network: true}
      ],
      baselines: %{"screenshots" => ["uat/checkout/confirmation.png"]}
    }
  end

  test "trace survives a JSON round-trip unchanged" do
    trace = sample_trace()
    assert Trace.from_json(Trace.to_json(trace)) == trace
  end

  test "map round-trip preserves step kinds as atoms" do
    trace = sample_trace()
    roundtripped = trace |> Trace.to_map() |> Trace.from_map()
    assert Enum.map(roundtripped.steps, & &1.kind) == Enum.map(trace.steps, & &1.kind)
    assert roundtripped == trace
  end

  test "to_map drops nil step fields but always keeps `from`" do
    map = Step.to_map(%Step{kind: :press, key: "Enter"})
    assert map == %{"kind" => "press", "key" => "Enter", "from" => %{}}
  end

  test "provenance back-reference is retained through serialization" do
    [_, click | _] = sample_trace() |> Trace.to_json() |> Trace.from_json() |> Map.fetch!(:steps)
    assert click.from["resolved_el"] == "el_3"
    assert click.from["observation_id"] == 9120
  end

  test "an unknown step kind raises rather than minting an atom" do
    assert_raise ArgumentError, ~r/unknown UAT step kind/, fn ->
      Step.from_map(%{"kind" => "teleport"})
    end
  end

  test "a trace missing a required field raises at load" do
    assert_raise ArgumentError, ~r/missing required field/, fn ->
      Trace.from_map(%{"criterion" => "no id here"})
    end
  end
end
