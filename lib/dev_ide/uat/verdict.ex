defmodule DevIDE.UAT.Verdict do
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

  The trusted `session_id` is passed in by the runner (from the `DevIDE.UAT.Run`),
  never taken from the agent-supplied verdict, which could lie.
  """

  alias DevIDE.Previews.ControlObservation

  @required_top ~w(passed criterion run_id session_id steps_taken assertions)
  @evidence_kinds ~w(element url errors screenshot)

  @doc """
  Validate `verdict` against the run's trusted `session_id`.

  Returns `{:ok, verdict}` when the shape is valid — with `passed`/assertion
  results coerced if any evidence failed grounding — or `{:error, errors}` when
  the shape itself is invalid.

  Options:

    * `:repo` — Ecto repo module (default `DevIde.Repo`), for tests
    * `:artifacts_root` — base dir for relative `artifact_path` (default from
      `:dev_ide, :preview_artifacts_root`)
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
    Application.app_dir(:dev_ide, "priv/uat/verdict_schema.json")
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
    repo = Keyword.get(opts, :repo, DevIde.Repo)
    artifacts_root = Keyword.get(opts, :artifacts_root, default_artifacts_root())

    {assertions, problems} =
      verdict
      |> Map.get("assertions", [])
      |> Enum.map_reduce([], &check_assertion_evidence(&1, &2, session_id, repo, artifacts_root))

    verdict
    |> Map.put("assertions", assertions)
    |> apply_problems(Enum.reverse(problems))
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
    full = if absolute?(path), do: path, else: Path.join(root, path)
    if File.exists?(full), do: nil, else: "artifact_path #{inspect(path)} does not exist"
  end

  defp artifact_problem(_evidence, _root), do: nil

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
    Application.get_env(:dev_ide, :preview_artifacts_root) ||
      Path.expand("priv/preview_artifacts")
  end
end
