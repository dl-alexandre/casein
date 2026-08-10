defmodule Casein.Terminals.OrphanedClaimsTest do
  use ExUnit.Case, async: true

  alias Casein.Attention.Delivery
  alias Casein.Terminals.OrphanedClaims

  describe "project/2" do
    test "claimed minus bound yields orphans sorted p0 first" do
      claimed = [
        %{number: 692, title: "inspector", labels: ["queue/claimed", "priority/p0"]},
        %{number: 812, title: "orphans", labels: ["queue/claimed", "priority/p1"]},
        %{number: 100, title: "bound work", labels: ["queue/claimed"]}
      ]

      snap = OrphanedClaims.project(claimed, [100, 999])

      assert snap.observe_state == :ok
      assert snap.orphan_count == 2
      assert snap.claimed_count == 3
      assert snap.bound_count == 2
      assert Enum.map(snap.orphans, & &1.number) == [692, 812]
      assert hd(snap.orphans).priority == "p0"
      assert hd(snap.orphans).needs_you?
      assert hd(snap.orphans).attention_reason == :orphaned_claim
    end

    test "all bound yields empty orphans without claiming unknown" do
      snap = OrphanedClaims.project([%{number: 1}], [%{issue: 1}])
      assert snap.observe_state == :ok
      assert snap.orphan_count == 0
      assert snap.orphans == []
      assert OrphanedClaims.summary(snap) == "no orphaned claims"
      refute OrphanedClaims.any?(snap)
      refute OrphanedClaims.unknown?(snap)
    end

    test "error claimed set is unknown, never calm empty" do
      snap = OrphanedClaims.project({:error, :gh_failed}, [812])

      assert snap.observe_state == :unknown
      assert snap.reason == :gh_failed
      assert snap.orphan_count == nil
      assert snap.bound_issues == [812]
      assert OrphanedClaims.unknown?(snap)
      refute OrphanedClaims.any?(snap)
      assert OrphanedClaims.summary(snap) =~ "unknown"
      refute OrphanedClaims.summary(snap) =~ "no orphaned"
    end

    test "binding map and tab rows both count as bound" do
      claimed = [10, 20, 30]
      bindings = %{"%1" => %{issue: 10}, "%2" => %{issue: 20}}
      tabs = [%{issue: 20}, %{"issue" => 30}]

      assert OrphanedClaims.project(claimed, bindings).orphan_count == 1
      assert hd(OrphanedClaims.project(claimed, bindings).orphans).number == 30

      assert OrphanedClaims.project(claimed, tabs).orphan_count == 1
      assert hd(OrphanedClaims.project(claimed, tabs).orphans).number == 10
    end
  end

  describe "observe/1" do
    test "injectable list_claimed port" do
      snap =
        OrphanedClaims.observe(
          list_claimed: fn -> {:ok, [%{number: 690, title: "stale", labels: ["priority/p0"]}]} end,
          bound: []
        )

      assert snap.observe_state == :ok
      assert snap.orphan_count == 1
      assert snap.source == :gh
    end

    test "failed list_claimed stays unknown" do
      snap =
        OrphanedClaims.observe(
          list_claimed: fn -> {:error, :gh_unavailable} end,
          bound: [1]
        )

      assert snap.observe_state == :unknown
      assert snap.reason == :gh_unavailable
    end

    test "supplied claimed list skips gh" do
      snap = OrphanedClaims.observe(claimed: [7, 8], bound: [7])
      assert snap.observe_state == :ok
      assert snap.source == :supplied
      assert Enum.map(snap.orphans, & &1.number) == [8]
    end
  end

  describe "attention path" do
    test "orphaned_claim urgency is on the shared Delivery table" do
      assert is_integer(Delivery.session_reason_urgency(:orphaned_claim))

      assert Delivery.session_reason_urgency(:orphaned_claim) <
               Delivery.session_reason_urgency(:idle)

      assert Delivery.session_reason_urgency(:orphaned_claim) >
               Delivery.session_reason_urgency(:blocked)

      assert OrphanedClaims.urgency() == Delivery.session_reason_urgency(:orphaned_claim)
    end
  end

  describe "unknown placeholder" do
    test "default unknown never looks like clear" do
      u = OrphanedClaims.unknown()
      assert u.observe_state == :unknown
      assert u.orphan_count == nil
      assert OrphanedClaims.summary(u) == "orphaned claims unknown · unscanned"
    end
  end
end
