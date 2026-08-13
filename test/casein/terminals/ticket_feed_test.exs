defmodule Casein.Terminals.TicketFeedTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.TicketFeed

  @now ~U[2026-08-12 23:30:00Z]

  setup do
    TicketFeed.ensure_table!()
    # Per-test repo key: the snapshot table is shared and named, so the key is
    # what keeps these async without cross-talk.
    {:ok, repo: "test/#{System.unique_integer([:positive])}"}
  end

  defp issue(number, opts \\ []) do
    %{
      "number" => number,
      "title" => Keyword.get(opts, :title, "issue #{number}"),
      "updatedAt" => Keyword.get(opts, :updated_at),
      "labels" => Keyword.get(opts, :labels, []),
      "__kind" => :issue
    }
  end

  defp pr(number, head_ref, opts \\ []) do
    %{
      "number" => number,
      "title" => Keyword.get(opts, :title, "pr #{number}"),
      "updatedAt" => Keyword.get(opts, :updated_at),
      "headRefName" => head_ref,
      "isDraft" => Keyword.get(opts, :draft, false),
      "labels" => [],
      "__kind" => :pr
    }
  end

  describe "project/2" do
    test "indexes issues by number and PRs by head branch" do
      snap =
        TicketFeed.project([issue(17_070), pr(912, "agent/claude/next-prompt")], now: @now)

      assert snap.observe_state == :ok
      assert snap.by_number[17_070].kind == :issue
      assert snap.by_number[912].kind == :pr
      assert snap.by_head_ref["agent/claude/next-prompt"].number == 912
      # Only PRs get a head-branch index — an issue has no branch to match.
      assert map_size(snap.by_head_ref) == 1
    end

    test "sorts newest-updated first, and undated tickets sink" do
      snap =
        TicketFeed.project(
          [
            issue(1, updated_at: "2026-08-10T00:00:00Z"),
            issue(2, updated_at: nil),
            pr(3, "b", updated_at: "2026-08-12T00:00:00Z")
          ],
          now: @now
        )

      assert Enum.map(snap.tickets, & &1.number) == [3, 1, 2]
    end

    test "infers PR from a head branch when kind is absent" do
      snap = TicketFeed.project([%{"number" => 5, "headRefName" => "feat/x"}], now: @now)
      assert hd(snap.tickets).kind == :pr
    end

    test "carries priority labels" do
      snap = TicketFeed.project([issue(9, labels: [%{"name" => "priority/p0"}])], now: @now)
      assert hd(snap.tickets).priority == "p0"
    end
  end

  describe "kind discipline" do
    test "unknown/1 is not an empty ok", %{repo: repo} do
      snap = TicketFeed.unknown(reason: :gh_failed)
      assert snap.observe_state == :unknown
      assert TicketFeed.unknown?(snap)
      assert snap.tickets == []
      assert TicketFeed.summary(snap) =~ "unknown"
      # And nothing was written for this repo by merely constructing one.
      assert TicketFeed.cached(repo: repo).observe_state == :unknown
    end

    test "a transport error observes as unknown, never as no work", %{repo: repo} do
      snap = TicketFeed.observe(repo: repo, tickets: {:error, :gh_failed})

      assert snap.observe_state == :unknown
      assert snap.reason == :gh_failed
      refute TicketFeed.summary(snap) =~ "0 open"
    end

    test "cached/1 is unknown before any refresh has landed", %{repo: repo} do
      assert TicketFeed.cached(repo: repo).observe_state == :unknown
      assert TicketFeed.cached(repo: repo).reason == :unscanned
    end

    test "claimed_from/2 refuses to answer from an unknown snapshot" do
      assert {:error, :gh_failed} =
               TicketFeed.claimed_from(TicketFeed.unknown(reason: :gh_failed))
    end
  end

  describe "claimed_from/2" do
    test "selects open claimed issues for this workspace only" do
      snap =
        TicketFeed.project(
          [
            issue(1, labels: [%{"name" => "queue/claimed"}, %{"name" => "workspace/casein"}]),
            issue(2, labels: [%{"name" => "queue/claimed"}, %{"name" => "workspace/other"}]),
            issue(3, labels: []),
            pr(4, "b")
          ],
          now: @now
        )

      assert {:ok, claims} = TicketFeed.claimed_from(snap)
      assert Enum.map(claims, & &1.number) == [1]
    end
  end

  describe "refresh_async/1" do
    test "lands a snapshot and broadcasts, then holds off inside the TTL", %{repo: repo} do
      TicketFeed.subscribe()

      assert :started =
               TicketFeed.refresh_async(
                 repo: repo,
                 tickets: [issue(17_070), pr(912, "agent/claude/next-prompt")]
               )

      assert_receive {:ticket_feed, :refreshed, ^repo}, 2_000

      snap = TicketFeed.cached(repo: repo)
      assert snap.observe_state == :ok
      assert snap.by_head_ref["agent/claude/next-prompt"].number == 912

      # Inside the TTL a second call must not spawn another `gh` — this is the
      # whole point of not hammering it on a 30s topology loop.
      assert :fresh = TicketFeed.refresh_async(repo: repo, tickets: [])
      assert TicketFeed.cached(repo: repo).observe_state == :ok
    end

    test "force refreshes regardless of TTL", %{repo: repo} do
      TicketFeed.subscribe()
      TicketFeed.observe(repo: repo, tickets: [issue(1)])

      assert :started =
               TicketFeed.refresh_async(repo: repo, force: true, tickets: [issue(1), issue(2)])

      assert_receive {:ticket_feed, :refreshed, ^repo}, 2_000
      assert map_size(TicketFeed.cached(repo: repo).by_number) == 2
    end

    test "resolves branches for supplied worktrees", %{repo: repo} do
      snap =
        TicketFeed.observe(
          repo: repo,
          tickets: [pr(912, "agent/claude/next-prompt")],
          branch_by_worktree: %{"/wt/a" => "agent/claude/next-prompt"}
        )

      assert snap.branch_by_worktree == %{"/wt/a" => "agent/claude/next-prompt"}
    end
  end
end
