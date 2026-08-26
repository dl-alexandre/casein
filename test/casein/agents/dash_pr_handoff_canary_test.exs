defmodule Casein.Agents.DashPrHandoffCanaryTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.JidoActions
  alias Casein.Agents.JidoActions.HandoffEvidence

  test "handoff_evidence is the Dash PR receipt and workers do not mutate GitHub PRs" do
    spec = JidoActions.spec("handoff_evidence")

    assert spec.capability == :handoff
    assert spec.supported
    assert spec.idempotent

    keys = Keyword.keys(HandoffEvidence.schema())

    assert :repository in keys
    assert :pull_request in keys
    assert :head_sha in keys
    assert :review_thread_ids in keys
    assert :handoff_target in keys
    assert :review_resolution in keys
    assert :merge_policy in keys

    names = JidoActions.names()
    refute "gh_pr_create" in names
    refute "gh_pr_approve" in names
    refute "gh_pr_resolve" in names
    refute "gh_pr_merge" in names
    refute "gh_pr_auto_merge" in names
  end
end
