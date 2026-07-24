defmodule Casein.UAT.VerdictTest do
  use Casein.DataCase, async: false

  alias Casein.Previews.{ControlObservation, ControlSession}
  alias Casein.UAT.Verdict

  setup do
    session = insert_session!()
    other = insert_session!()
    {:ok, session_id: session.id, other_id: other.id}
  end

  test "a grounded pass validates and stays passed", %{session_id: sid} do
    obs = insert_observation!(sid, "url", %{"url" => "/confirmation"})
    verdict = build_verdict(sid, true, [assertion("reached confirmation", "pass", "url", obs.id)])

    assert {:ok, validated} = Verdict.validate(verdict, sid)
    assert validated["passed"] == true
    refute Map.has_key?(validated, "evidence_problems")
  end

  test "a malformed verdict fails the shape layer", %{session_id: sid} do
    bad = build_verdict(sid, true, []) |> Map.delete("criterion")

    assert {:error, errors} = Verdict.validate(bad, sid)
    assert Enum.any?(errors, &(&1 =~ "missing required field criterion"))
  end

  test "evidence missing the observation_id fails the shape layer", %{session_id: sid} do
    a = %{"desc" => "x", "result" => "pass", "evidence" => %{"kind" => "url"}}
    verdict = build_verdict(sid, true, [a])

    assert {:error, errors} = Verdict.validate(verdict, sid)
    assert Enum.any?(errors, &(&1 =~ "observation_id must be an integer"))
  end

  test "a pass citing another session's observation is coerced to fail", %{
    session_id: sid,
    other_id: oid
  } do
    foreign = insert_observation!(oid, "url", %{"url" => "/confirmation"})

    verdict =
      build_verdict(sid, true, [assertion("reached confirmation", "pass", "url", foreign.id)])

    assert {:ok, validated} = Verdict.validate(verdict, sid)
    assert validated["passed"] == false
    assert validated["failure_reason"] == "evidence_validation_failed"
    assert [%{"result" => "fail"}] = validated["assertions"]
    assert [problem] = validated["evidence_problems"]
    assert problem =~ "not run session"
  end

  test "a pass citing a non-existent observation is coerced to fail", %{session_id: sid} do
    verdict = build_verdict(sid, true, [assertion("x", "pass", "url", 999_999)])

    assert {:ok, validated} = Verdict.validate(verdict, sid)
    assert validated["passed"] == false
    assert [problem] = validated["evidence_problems"]
    assert problem =~ "not found"
  end

  test "a pass citing a missing artifact is coerced to fail", %{session_id: sid} do
    obs = insert_observation!(sid, "screenshot", %{})

    ev =
      "screenshot" |> assertion_evidence(obs.id) |> Map.put("artifact_path", "nope/missing.png")

    a = %{"desc" => "shot", "result" => "pass", "evidence" => ev}
    verdict = build_verdict(sid, true, [a])

    assert {:ok, validated} = Verdict.validate(verdict, sid, artifacts_root: tmp_root())
    assert validated["passed"] == false
    assert [problem] = validated["evidence_problems"]
    assert problem =~ "does not exist"
  end

  test "a pass with an existing artifact validates", %{session_id: sid} do
    root = tmp_root()
    File.mkdir_p!(Path.join(root, "shots"))
    File.write!(Path.join(root, "shots/ok.png"), "x")
    obs = insert_observation!(sid, "screenshot", %{})
    ev = "screenshot" |> assertion_evidence(obs.id) |> Map.put("artifact_path", "shots/ok.png")
    a = %{"desc" => "shot", "result" => "pass", "evidence" => ev}
    verdict = build_verdict(sid, true, [a])

    assert {:ok, validated} = Verdict.validate(verdict, sid, artifacts_root: root)
    assert validated["passed"] == true
  end

  test "a pass whose error_count disagrees with the observation is coerced to fail", %{
    session_id: sid
  } do
    obs = insert_observation!(sid, "console_errors", %{"errors" => ["boom", "bang"]})
    ev = "errors" |> assertion_evidence(obs.id) |> Map.put("error_count", 0)
    a = %{"desc" => "no errors", "result" => "pass", "evidence" => ev}
    verdict = build_verdict(sid, true, [a])

    assert {:ok, validated} = Verdict.validate(verdict, sid)
    assert validated["passed"] == false
    assert [problem] = validated["evidence_problems"]
    assert problem =~ "does not match observation"
  end

  test "a matching error_count validates", %{session_id: sid} do
    obs = insert_observation!(sid, "console_errors", %{"errors" => []})
    ev = "errors" |> assertion_evidence(obs.id) |> Map.put("error_count", 0)
    a = %{"desc" => "no errors", "result" => "pass", "evidence" => ev}
    verdict = build_verdict(sid, true, [a])

    assert {:ok, validated} = Verdict.validate(verdict, sid)
    assert validated["passed"] == true
  end

  test "a passed verdict with NO assertions is coerced to fail (no self-cert)", %{session_id: sid} do
    verdict = build_verdict(sid, true, [])

    assert {:ok, validated} = Verdict.validate(verdict, sid)
    assert validated["passed"] == false
    assert validated["failure_reason"] == "no_grounded_assertions"
  end

  test "a passed verdict containing a fail assertion is coerced to fail", %{session_id: sid} do
    obs = insert_observation!(sid, "url", %{"url" => "/x"})
    a = %{"desc" => "broke", "result" => "fail", "evidence" => assertion_evidence("url", obs.id)}
    verdict = build_verdict(sid, true, [a])

    assert {:ok, validated} = Verdict.validate(verdict, sid)
    assert validated["passed"] == false
    assert validated["failure_reason"] == "assertion_failed"
  end

  test "an absolute artifact_path is rejected (confined to artifacts_root)", %{session_id: sid} do
    obs = insert_observation!(sid, "screenshot", %{})
    ev = "screenshot" |> assertion_evidence(obs.id) |> Map.put("artifact_path", "/etc/hostname")
    a = %{"desc" => "shot", "result" => "pass", "evidence" => ev}
    verdict = build_verdict(sid, true, [a])

    assert {:ok, validated} = Verdict.validate(verdict, sid, artifacts_root: tmp_root())
    assert validated["passed"] == false
    assert [problem] = validated["evidence_problems"]
    assert problem =~ "must be relative"
  end

  test "a traversal artifact_path escaping the root is rejected", %{session_id: sid} do
    root = tmp_root()
    File.mkdir_p!(root)
    obs = insert_observation!(sid, "screenshot", %{})

    ev =
      "screenshot" |> assertion_evidence(obs.id) |> Map.put("artifact_path", "../../etc/hostname")

    a = %{"desc" => "shot", "result" => "pass", "evidence" => ev}
    verdict = build_verdict(sid, true, [a])

    assert {:ok, validated} = Verdict.validate(verdict, sid, artifacts_root: root)
    assert validated["passed"] == false
    assert [problem] = validated["evidence_problems"]
    assert problem =~ "escapes artifacts_root"
  end

  # --- helpers --------------------------------------------------------------

  defp build_verdict(session_id, passed, assertions) do
    %{
      "passed" => passed,
      "criterion" => "some criterion",
      "run_id" => "uat_run_test",
      "session_id" => session_id,
      "steps_taken" => [],
      "assertions" => assertions
    }
  end

  defp assertion(desc, result, kind, observation_id) do
    %{"desc" => desc, "result" => result, "evidence" => assertion_evidence(kind, observation_id)}
  end

  defp assertion_evidence(kind, observation_id) do
    %{"kind" => kind, "observation_id" => observation_id}
  end

  defp insert_session!() do
    %ControlSession{}
    |> ControlSession.changeset(%{workspace_id: "uat-test", surface: "app", adapter: "memory"})
    |> Repo.insert!()
  end

  defp insert_observation!(session_id, kind, data) do
    %ControlObservation{}
    |> ControlObservation.changeset(%{session_id: session_id, kind: kind, data: data})
    |> Repo.insert!()
  end

  defp tmp_root do
    Casein.TmpWorkspace.root!("uat-artifacts")
  end
end
