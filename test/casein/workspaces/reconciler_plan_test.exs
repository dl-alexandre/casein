defmodule Casein.Workspaces.ReconcilerPlanTest do
  @moduledoc """
  Guard-by-guard coverage of the reconciler's decision core.

  Each guard here is the thing standing between "one workspace was deleted"
  and "every record on a shared box was retired", so each gets a test that
  fails loudly if it is removed.
  """
  use ExUnit.Case, async: true

  alias Casein.Workspace
  alias Casein.Workspaces.Reconciler.Plan
  alias Casein.Workspaces.State.WorkspaceRecord

  @now ~U[2026-07-24 12:00:00.000000Z]
  @grace_ms :timer.minutes(30)

  defp listed(id, user), do: %Workspace{id: id, name: id, user: user, status: :running}

  defp record(id, opts \\ []) do
    %WorkspaceRecord{
      external_id: id,
      name: id,
      user: Keyword.get(opts, :user, "dalexandre"),
      status: Keyword.get(opts, :status, "running"),
      # Default well outside the grace window: tests that care about the grace
      # guard set this explicitly.
      last_seen_at: Keyword.get(opts, :last_seen_at, DateTime.add(@now, -1, :day))
    }
  end

  defp build(listed, records, opts \\ []) do
    Plan.build(listed, records,
      now: @now,
      grace_ms: @grace_ms,
      scope: Keyword.get(opts, :scope, :global)
    )
  end

  defp retired_ids(plan), do: Enum.map(plan.retire, & &1.external_id)

  describe "the base case" do
    test "retires a record the listing no longer contains" do
      plan = build([listed("alive", "dalexandre")], [record("alive"), record("deleted")])

      assert retired_ids(plan) == ["deleted"]
    end

    test "keeps a record the listing still contains" do
      plan = build([listed("alive", "dalexandre")], [record("alive")])

      assert plan.retire == []
      assert plan.skipped == %{present: 1}
    end
  end

  describe "multi-tenancy guard" do
    test "a listing scoped to one user cannot retire another user's records" do
      records = [record("mine-deleted", user: "dalexandre"), record("theirs", user: "jgiles")]

      plan = build([listed("mine-alive", "dalexandre")], records, scope: {:user, "dalexandre"})

      assert retired_ids(plan) == ["mine-deleted"]
      assert plan.skipped[:out_of_scope] == 1
    end

    test "a global listing may retire any user's records" do
      records = [record("mine", user: "dalexandre"), record("theirs", user: "jgiles")]

      plan = build([listed("other", "msoares")], records, scope: :global)

      assert retired_ids(plan) == ["mine", "theirs"]
    end

    test "a record with no recorded owner is never retired under a user scope" do
      plan =
        build([listed("alive", "dalexandre")], [record("ownerless", user: nil)],
          scope: {:user, "dalexandre"}
        )

      assert plan.retire == []
      assert plan.skipped == %{out_of_scope: 1}
    end
  end

  describe "synthetic workspaces" do
    test "scratch and folder-attach records are never retired" do
      records = [
        record("__scratch__"),
        record("folder:/data/workspaces/dalexandre/casein")
      ]

      plan = build([listed("alive", "dalexandre")], records)

      assert plan.retire == []
      assert plan.skipped == %{synthetic: 2}
    end
  end

  describe "grace window" do
    test "a record seen inside the window is left alone" do
      recent = record("recent", last_seen_at: DateTime.add(@now, -60, :second))

      plan = build([listed("alive", "dalexandre")], [recent])

      assert plan.retire == []
      assert plan.skipped == %{within_grace: 1}
    end

    test "a record seen just outside the window is retired" do
      aged = record("aged", last_seen_at: DateTime.add(@now, -@grace_ms - 1, :millisecond))

      plan = build([listed("alive", "dalexandre")], [aged])

      assert retired_ids(plan) == ["aged"]
    end

    test "a record that was never seen is not retired" do
      plan = build([listed("alive", "dalexandre")], [record("never", last_seen_at: nil)])

      assert plan.retire == []
      assert plan.skipped == %{within_grace: 1}
    end
  end

  describe "idempotence" do
    test "an already-retired record is not retired again" do
      plan = build([listed("alive", "dalexandre")], [record("gone", status: "stale")])

      assert plan.retire == []
      assert plan.skipped == %{already_retired: 1}
    end

    test "re-running against the same inputs is a no-op after the first pass" do
      records = [record("alive"), record("deleted")]
      first = build([listed("alive", "dalexandre")], records)

      retired_now =
        Enum.map(records, fn r ->
          if r.external_id in retired_ids(first),
            do: %{r | status: WorkspaceRecord.stale_status()},
            else: r
        end)

      assert build([listed("alive", "dalexandre")], retired_now).retire == []
    end
  end

  describe "reporting" do
    test "carries the scope and listing size for the audit trail" do
      plan = build([listed("a", "u"), listed("b", "u")], [record("gone")], scope: {:user, "u"})

      assert plan.scope == {:user, "u"}
      assert plan.listed == 2
    end
  end
end
