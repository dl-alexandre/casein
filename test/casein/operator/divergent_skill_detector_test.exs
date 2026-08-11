defmodule Casein.Operator.DivergentSkillDetectorTest do
  use ExUnit.Case, async: true

  alias Casein.Operator.Detectors

  @now ~U[2026-08-11 09:00:00Z]

  describe "divergent_skill/2" do
    test "a skill whose copies disagree is a warn, naming every root" do
      risks = Detectors.divergent_skill([skill("preview-ui-walk", :divergent, 4, 12)], @now)

      assert [risk] = risks
      assert risk.id == :divergent_skill
      assert risk.severity == :warn
      assert risk.subject == "preview-ui-walk"
      assert risk.detected_at == @now
      assert risk.evidence.versions == 4
      assert risk.evidence.copies == 12
      assert length(risk.evidence.roots) == 12
      assert risk.suggestion =~ "Relaunch"
    end

    test "an unreadable copy is info, not warn, and says so" do
      skill = %{
        name: "delegate-to-worker",
        state: :unknown,
        fingerprints: [],
        copies: [%{label: "profile:x", path: "/p/x", fingerprint: nil, reason: :unreadable}]
      }

      assert [risk] = Detectors.divergent_skill([skill], @now)
      assert risk.severity == :info
      assert risk.evidence.state == :unknown
      assert risk.suggestion =~ "permissions"
      assert [%{reason: :unreadable}] = risk.evidence.roots
    end

    test "agreeing skills raise nothing" do
      skills = [skill("gh-stack", :identical, 1, 12), skill("verify", :single, 1, 1)]

      assert Detectors.divergent_skill(skills, @now) == []
    end

    test "evidence carries fingerprints short and paths whole, never skill bodies" do
      assert [risk] = Detectors.divergent_skill([skill("x", :divergent, 2, 2)], @now)

      for root <- risk.evidence.roots do
        assert String.length(root.fingerprint) == 12
        assert root.path =~ "/p/"
      end
    end

    test "no skills at all is not a risk" do
      assert Detectors.divergent_skill([], @now) == []
      assert Detectors.divergent_skill(nil, @now) == []
    end
  end

  defp skill(name, state, versions, copies) do
    %{
      name: name,
      state: state,
      fingerprints: Enum.map(1..versions, &String.duplicate("#{&1}", 64)),
      copies:
        Enum.map(1..copies, fn i ->
          %{
            label: "root-#{i}",
            path: "/p/#{i}/#{name}",
            fingerprint: String.duplicate("#{rem(i, versions) + 1}", 64),
            reason: nil
          }
        end)
    }
  end
end
