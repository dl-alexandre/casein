defmodule Casein.UAT.Verdict do
  @moduledoc """
  Validates an acceptance-agent verdict in two layers:

    1. **Shape** — required keys, types, and enums (the contract documented in
       `priv/uat/verdict_schema.json`). Hand-rolled so Phase 0 needs no new
       JSON-schema dependency.
    2. **Grounding** — every assertion's `evidence` must point at a real
       observation that belongs to *this run's* session, any cited
       `artifact_path` must exist on disk, and any `error_count` must match the
       cited observation. An unprovable `pass` is coerced to `fail` with
       `failure_reason: "evidence_validation_failed"` — the agent cannot
       self-certify.

  The trusted `session_id` is passed in by the runner (from the `Casein.UAT.Run`),
  never taken from the agent-supplied verdict, which could lie.

  ## What grounding does and does not prove

  Grounding proves **provenance**: each cited observation exists and belongs to
  this run's session, the artifact exists under `artifacts_root`, and a claimed
  `error_count` matches. A `passed: true` verdict is additionally reconciled —
  it must carry at least one assertion and no `fail` assertion, or it is coerced
  to a fail (so an agent cannot self-certify with `assertions: []`).

  It does **not** prove the observation's content semantically supports the
  claim — an agent could cite a real same-session observation that doesn't
  actually show what the assertion says. Tightening evidence-vs-claim content
  validation (e.g. URL/element payload checks) is a known follow-up.
  """

  alias Casein.Previews.ControlObservation

  @required_top ~w(passed criterion run_id session_id steps_taken assertions)
  @evidence_kinds ~w(element url errors screenshot)

  @doc """
  Validate `verdict` against the run's trusted `session_id`.

  Returns `{:ok, verdict}` when the shape is valid — with `passed`/assertion
  results coerced if any evidence failed grounding — or `{:error, errors}` when
  the shape itself is invalid.

  Options:

    * `:repo` — Ecto repo module (default `Casein.Repo`), for tests
    * `:artifacts_root` — base dir for relative `artifact_path` (default from
      `:casein, :preview_artifacts_root`)
  """
  @spec validate(map(), integer(), keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(verdict, session_id, opts \\ []) when is_map(verdict) do
    case validate_shape(verdict) do
      :ok -> {:ok, ground(verdict, session_id, opts)}
      {:error, _} = err -> err
    end
  end

  @doc "Path to the JSON-schema contract documenting the verdict shape."
  @spec schema_path() :: String.t()
  def schema_path do
    Application.app_dir(:casein, "priv/uat/verdict_schema.json")
  end

  # --- Layer 1: shape -------------------------------------------------------

  defp validate_shape(verdict) do
    errors =
      []
      |> check_required(verdict)
      |> check(is_boolean(verdict["passed"]), "passed must be a boolean")
      |> check(is_binary(verdict["criterion"]), "criterion must be a string")
      |> check(is_binary(verdict["run_id"]), "run_id must be a string")
      |> check(is_integer(verdict["session_id"]), "session_id must be an integer")
      |> check(is_list(verdict["steps_taken"]), "steps_taken must be an array")
      |> check(is_list(verdict["assertions"]), "assertions must be an array")
      |> check_assertions(verdict["assertions"])

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp check_required(errors, verdict) do
    Enum.reduce(@required_top, errors, fn key, acc ->
      if Map.has_key?(verdict, key), do: acc, else: ["missing required field #{key}" | acc]
    end)
  end

  defp check_assertions(errors, assertions) when is_list(assertions) do
    assertions
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {assertion, i}, acc -> check_assertion(acc, assertion, i) end)
  end

  defp check_assertions(errors, _), do: errors

  defp check_assertion(errors, %{} = a, i) do
    evidence = a["evidence"]

    errors
    |> check(is_binary(a["desc"]), "assertions[#{i}].desc must be a string")
    |> check(a["result"] in ["pass", "fail"], "assertions[#{i}].result must be pass|fail")
    |> check(is_map(evidence), "assertions[#{i}].evidence must be an object")
    |> check(
      is_map(evidence) and evidence["kind"] in @evidence_kinds,
      "assertions[#{i}].evidence.kind must be one of #{inspect(@evidence_kinds)}"
    )
    |> check(
      is_map(evidence) and is_integer(evidence["observation_id"]),
      "assertions[#{i}].evidence.observation_id must be an integer"
    )
  end

  defp check_assertion(errors, _, i), do: ["assertions[#{i}] must be an object" | errors]

  defp check(errors, true, _msg), do: errors
  defp check(errors, _false, msg), do: [msg | errors]

  # --- Layer 2: grounding ---------------------------------------------------

  defp ground(verdict, session_id, opts) do
    repo = Keyword.get(opts, :repo, Casein.Repo)
    artifacts_root = Keyword.get(opts, :artifacts_root, default_artifacts_root())

    {assertions, problems} =
      verdict
      |> Map.get("assertions", [])
      |> Enum.map_reduce([], &check_assertion_evidence(&1, &2, session_id, repo, artifacts_root))

    verdict
    |> Map.put("assertions", assertions)
    |> apply_problems(Enum.reverse(problems))
    |> reconcile_passed()
  end

  # A claimed pass must be backed by at least one assertion and zero failing
  # assertions (after grounding). An empty assertion list or any remaining
  # `fail` means the agent self-certified — coerce to a fail. Closes the
  # `passed: true, assertions: []` and `passed: true` + failing-assertion holes.
  defp reconcile_passed(%{"passed" => true} = verdict) do
    results = verdict |> Map.get("assertions", []) |> Enum.map(& &1["result"])

    cond do
      results == [] -> coerce_fail(verdict, "no_grounded_assertions")
      "fail" in results -> coerce_fail(verdict, "assertion_failed")
      true -> verdict
    end
  end

  defp reconcile_passed(verdict), do: verdict

  defp coerce_fail(verdict, reason) do
    verdict
    |> Map.put("passed", false)
    |> Map.put_new("failure_reason", reason)
  end

  defp check_assertion_evidence(assertion, acc, session_id, repo, artifacts_root) do
    case assertion_problem(assertion, session_id, repo, artifacts_root) do
      nil -> {assertion, acc}
      problem -> {downgrade_pass(assertion), [problem | acc]}
    end
  end

  # Only a claimed pass is downgraded by failed grounding; a fail stays a fail.
  defp downgrade_pass(%{"result" => "pass"} = assertion), do: Map.put(assertion, "result", "fail")
  defp downgrade_pass(assertion), do: assertion

  defp apply_problems(verdict, []), do: verdict

  defp apply_problems(verdict, problems) do
    verdict
    |> Map.put("passed", false)
    |> Map.put("failure_reason", "evidence_validation_failed")
    |> Map.put("evidence_problems", problems)
  end

  # Returns a problem string, or nil when the assertion's evidence checks out.
  defp assertion_problem(%{"evidence" => evidence} = _a, session_id, repo, artifacts_root)
       when is_map(evidence) do
    obs_id = evidence["observation_id"]

    case repo.get(ControlObservation, obs_id) do
      nil ->
        "observation #{inspect(obs_id)} not found"

      %ControlObservation{session_id: obs_session} when obs_session != session_id ->
        "observation #{obs_id} belongs to session #{obs_session}, not run session #{session_id}"

      %ControlObservation{} = obs ->
        artifact_problem(evidence, artifacts_root) || error_count_problem(evidence, obs)
    end
  end

  defp assertion_problem(_a, _session_id, _repo, _root), do: "assertion has no evidence object"

  defp artifact_problem(%{"artifact_path" => path}, root)
       when is_binary(path) and path != "" do
    # Confine to artifacts_root: reject absolute paths and any traversal that
    # escapes the root, so a pass can't be "kept" by citing an unrelated file
    # (and the existence check can't be used as a filesystem oracle).
    cond do
      absolute?(path) -> "artifact_path #{inspect(path)} must be relative to artifacts_root"
      escapes_root?(root, path) -> "artifact_path #{inspect(path)} escapes artifacts_root"
      File.exists?(Path.join(root, path)) -> nil
      true -> "artifact_path #{inspect(path)} does not exist"
    end
  end

  defp artifact_problem(_evidence, _root), do: nil

  defp escapes_root?(root, path) do
    root_abs = Path.expand(root)
    full = Path.expand(Path.join(root, path))
    not String.starts_with?(full, root_abs <> "/") and full != root_abs
  end

  defp error_count_problem(%{"kind" => "errors", "error_count" => claimed} = _e, obs)
       when is_integer(claimed) do
    actual = obs |> observation_errors() |> length()

    if claimed == actual,
      do: nil,
      else: "error_count #{claimed} does not match observation (#{actual} errors)"
  end

  defp error_count_problem(_evidence, _obs), do: nil

  defp observation_errors(%ControlObservation{data: %{"errors" => errors}}) when is_list(errors),
    do: errors

  defp observation_errors(_obs), do: []

  defp absolute?(path), do: Path.type(path) == :absolute

  defp default_artifacts_root do
    Application.get_env(:casein, :preview_artifacts_root) ||
      Application.app_dir(:casein, "priv/preview_artifacts")
  end
end
