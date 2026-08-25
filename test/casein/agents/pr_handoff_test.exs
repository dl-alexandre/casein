defmodule Casein.Agents.PrHandoffTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.PrHandoff

  @sha String.duplicate("a", 40)

  test "validates, redacts, and keys a worker receipt" do
    receipt = %{
      handoff_id: "handoff-1",
      worker_run_id: "run-1",
      repository: "owner/repo",
      base_branch: "develop",
      head_branch: "worker/feature",
      head_sha: @sha,
      pr_number: 42,
      pr_url: "https://github.com/owner/repo/pull/42",
      tests: [
        %{command: "mix test", status: "passed", output: "do not persist this"}
      ],
      review_threads: %{
        total: 1,
        unresolved: 0,
        items: [%{id: "thread-1", resolved: true, body: "do not persist this"}]
      }
    }

    assert {:ok, normalized} = PrHandoff.validate(receipt)
    assert normalized.schema_version == 1
    assert normalized.handoff_status == "ready"
    assert normalized.tests == [%{command: "mix test", status: "passed"}]
    assert normalized.review_threads.items == [%{id: "thread-1", resolved: true}]
    assert PrHandoff.idempotency_key(normalized) == "owner/repo:pr:42:#{@sha}"
  end

  test "rejects incomplete, unsafe, and malformed handoffs" do
    assert {:error, %{error: :missing_handoff_field, field: :head_sha}} =
             PrHandoff.validate(%{
               handoff_id: "handoff-1",
               repository: "owner/repo",
               base_branch: "develop",
               head_branch: "worker/feature"
             })

    assert {:error, %{error: :invalid_handoff, field: :head_sha}} =
             PrHandoff.validate(%{
               handoff_id: "handoff-1",
               repository: "owner/repo",
               base_branch: "develop",
               head_branch: "worker/feature",
               head_sha: String.duplicate("z", 40)
             })

    assert {:error, %{error: :invalid_handoff, field: :head_branch}} =
             PrHandoff.validate(%{
               handoff_id: "handoff-1",
               repository: "owner/repo",
               base_branch: "develop",
               head_branch: "worker/feature:unsafe",
               head_sha: @sha
             })
  end
end
