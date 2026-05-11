defmodule DevIDE.Runners.ContractTest do
  use ExUnit.Case, async: true

  alias DevIDE.Runners
  alias DevIDE.Runners.{Assignment, Failure, ProgressReport}

  @assignment_id "00000000-0000-0000-0000-000000000001"
  @report_id "00000000-0000-0000-0000-000000000101"

  test "versioned fixtures describe the runner protocol v1 envelopes" do
    assert fixture("enqueue_request.json")["execution_protocol"] == Runners.protocol()
    assert fixture("poll_request.json")["protocol"] == Runners.protocol()
    assert fixture("report_request.json")["claim_token"] == "claim-token-contract"
    assert fixture("complete_request.json")["report_id"] == "runner-terminal-1"
    assert fixture("fail_request.json")["failure_class"] == "action_failed"

    assert fixture("error_claim_rejected.json") == %{
             "error" => "capabilities_required",
             "failure_class" => "claim_rejected"
           }

    assert fixture("error_report_rejected.json") == %{
             "error" => "claim_token_invalid",
             "failure_class" => "report_rejected"
           }
  end

  test "assignment and report payloads keep the fixture contract stable" do
    assignment = %Assignment{
      id: @assignment_id,
      workspace_id: "ws-contract",
      safe_action_id: "command:test",
      safe_action_version: 1,
      status: "queued",
      requested_by: "jx",
      queued_at: dt!("2026-05-10T01:00:00Z"),
      metadata: fixture("enqueue_response.json")["assignment"]["metadata"]
    }

    assert Jason.decode!(Jason.encode!(Runners.assignment_payload(assignment))) ==
             fixture("enqueue_response.json")["assignment"]

    claimed = %{
      assignment
      | status: "claimed",
        claimed_by: "runner-a",
        claim_token: "claim-token-contract",
        claimed_at: dt!("2026-05-10T01:01:00Z"),
        lease_expires_at: dt!("2026-05-10T01:16:00Z")
    }

    assert Jason.decode!(
             Jason.encode!(Runners.assignment_payload(claimed, include_claim_token: true))
           ) == fixture("poll_response.json")["assignment"]

    report = %ProgressReport{
      id: @report_id,
      assignment_id: @assignment_id,
      client_report_id: "runner-report-1",
      runner_id: "runner-a",
      position: 1,
      event: "started",
      message: "mix test started",
      observed_at: dt!("2026-05-10T01:01:10Z"),
      inserted_at: dt!("2026-05-10T01:01:10Z")
    }

    assert Jason.decode!(Jason.encode!(Runners.report_payload(report))) ==
             fixture("report_response.json")["report"]
  end

  test "failure taxonomy is stable and complete" do
    assert Failure.classes() == ~w(
             enqueue_failed
             claim_rejected
             lease_expired
             report_rejected
             action_failed
             replay_mismatch
             runner_lost
           )

    assert Failure.class(:safe_action_not_allowed) == "enqueue_failed"
    assert Failure.class(:capabilities_required) == "claim_rejected"
    assert Failure.class(:lease_expired) == "lease_expired"
    assert Failure.class(:claim_token_invalid) == "report_rejected"
    assert Failure.class(:action_failed) == "action_failed"
    assert Failure.class(:replay_mismatch) == "replay_mismatch"
    assert Failure.class(:runner_lost) == "runner_lost"
  end

  defp fixture(name) do
    __DIR__
    |> Path.join("../../fixtures/jx_runner_v1/#{name}")
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
  end

  defp dt!(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end
end
