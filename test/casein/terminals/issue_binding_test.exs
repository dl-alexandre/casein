defmodule Casein.Terminals.IssueBindingTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.IssueBinding

  @ws "ws-1"
  @session "casein_alpha_u-dev"

  setup do
    IssueBinding.clear_all()
    on_exit(&IssueBinding.clear_all/0)
    :ok
  end

  describe "normalize_issue/1" do
    test "accepts the forms that actually turn up in claims" do
      assert IssueBinding.normalize_issue(678) == 678
      assert IssueBinding.normalize_issue("678") == 678
      assert IssueBinding.normalize_issue("#678") == 678
      assert IssueBinding.normalize_issue("  #678  ") == 678

      assert IssueBinding.normalize_issue("https://github.com/dl-alexandre/casein/issues/678") ==
               678
    end

    test "rejects anything it cannot read as an issue number" do
      # A malformed value must not produce a half-written binding, and must not
      # silently become issue 0 or 1.
      for bad <- ["", "#", "abc", "12abc", "#0", 0, -5, nil, %{}, "issues/"] do
        assert IssueBinding.normalize_issue(bad) == nil, "expected #{inspect(bad)} to be rejected"
      end
    end
  end

  describe "bind and clear" do
    test "binds an issue to a pane and reads it back" do
      assert {:ok, entry} = IssueBinding.bind(@ws, @session, "%1", "#678", url: "http://x/678")
      assert entry.issue == 678
      assert entry.url == "http://x/678"
      assert %DateTime{} = entry.bound_at

      assert %{issue: 678} = IssueBinding.get(@session, "%1")
    end

    test "re-binding replaces rather than accumulating" do
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678)
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 680)

      assert %{issue: 680} = IssueBinding.get(@session, "%1")
      assert IssueBinding.panes_for_issue(678) == []
    end

    test "clearing is idempotent" do
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678)
      assert :ok = IssueBinding.clear(@ws, @session, "%1")
      assert IssueBinding.get(@session, "%1") == nil
      # Clearing an unbound pane must not raise — release runs on paths that may
      # not have bound anything.
      assert :ok = IssueBinding.clear(@ws, @session, "%1")
    end

    test "an invalid issue leaves no binding at all" do
      assert {:error, :invalid_issue} = IssueBinding.bind(@ws, @session, "%1", "not-an-issue")
      assert IssueBinding.get(@session, "%1") == nil
    end
  end

  describe "inverse lookup" do
    test "answers who is on an issue, across sessions" do
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678)
      {:ok, _} = IssueBinding.bind(@ws, "casein_beta_u-dev", "%9", 678)
      {:ok, _} = IssueBinding.bind(@ws, @session, "%2", 680)

      # This is the check that distinguishes an abandoned queue/claimed label
      # from live work.
      assert IssueBinding.panes_for_issue(678) == [
               {"casein_alpha_u-dev", "%1"},
               {"casein_beta_u-dev", "%9"}
             ]

      assert IssueBinding.panes_for_issue(680) == [{@session, "%2"}]
      assert IssueBinding.panes_for_issue(999) == []
    end
  end

  describe "pruning on pane close" do
    test "drops bindings for panes that no longer exist" do
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678)
      {:ok, _} = IssueBinding.bind(@ws, @session, "%2", 680)

      IssueBinding.prune_session(@session, ["%2"])
      # cast — settle before asserting
      _ = IssueBinding.get(@session, "%2")

      assert IssueBinding.get(@session, "%1") == nil
      assert %{issue: 680} = IssueBinding.get(@session, "%2")
    end

    test "pruning one session never touches another" do
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678)
      {:ok, _} = IssueBinding.bind(@ws, "casein_beta_u-dev", "%1", 680)

      IssueBinding.prune_session(@session, [])
      _ = IssueBinding.get(@session, "%1")

      assert IssueBinding.get(@session, "%1") == nil
      assert %{issue: 680} = IssueBinding.get("casein_beta_u-dev", "%1")
    end
  end

  describe "topology enrichment" do
    test "attaches issue to the bound pane and its window" do
      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678)

      enriched = IssueBinding.enrich_topology(topology(), @session)

      assert [%{id: "%1", issue: 678}, pane2] = enriched.panes
      refute Map.has_key?(pane2, :issue)
      # A collapsed window still shows what it is working on.
      assert [%{id: "@1", issue: 678}, window2] = enriched.windows
      refute Map.has_key?(window2, :issue)
    end

    test "a topology with no bindings is returned untouched" do
      assert IssueBinding.enrich_topology(topology(), @session) == topology()
    end

    test "a malformed topology passes through" do
      assert IssueBinding.enrich_topology(%{windows: []}, @session) == %{windows: []}
    end
  end

  describe "broadcast" do
    test "subscribers see bind and clear" do
      :ok = IssueBinding.subscribe(@ws)

      {:ok, _} = IssueBinding.bind(@ws, @session, "%1", 678)
      assert_receive {:issue_binding_updated, @session, "%1", %{issue: 678}}

      :ok = IssueBinding.clear(@ws, @session, "%1")
      assert_receive {:issue_binding_updated, @session, "%1", nil}
    end

    test "a nil workspace does not crash the bind" do
      assert {:ok, %{issue: 678}} = IssueBinding.bind(nil, @session, "%1", 678)
    end
  end

  defp topology do
    p1 = %{id: "%1", window_id: "@1"}
    p2 = %{id: "%2", window_id: "@2"}

    %{
      panes: [p1, p2],
      windows: [
        %{id: "@1", pane_list: [p1]},
        %{id: "@2", pane_list: [p2]}
      ]
    }
  end
end
