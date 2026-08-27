defmodule Casein.Agents.JidoWorkcell.Receipt do
  @moduledoc """
  Strict, redacted completion receipt shared with Dash.

  This is the producer-side Gate 0 contract. Casein records the worker's
  commit/push result; Dash/Verda owns every live PR, review, CI, approval,
  merge, and deploy operation. A handoff receipt and a review-thread action
  therefore have different idempotency namespaces.
  """

  alias Casein.Agents.JidoWorkcell.Git.Scope
  alias Casein.Agents.JidoWorkcell.{Limits, OwnerRef}

  @schema_version 1
  @contract_name "casein-dash-handoff"
  @contract_version "1.0"
  @kind "jido_worker_handoff"
  @sources ~w(v3_casein casein_worker dash_verda)
  @producer_sources ~w(v3_casein casein_worker)
  @sha_re ~r/\A[0-9a-f]{40}\z/
  @max_tests Limits.max_tests()
  @max_artifacts Limits.max_artifacts()

  @allowed_attr_keys [
    :paths,
    :message,
    :source,
    :receipt_id,
    :handoff_id,
    :workspace_id,
    :owner_ref,
    :runtime_id,
    :worker_id,
    :release_sha,
    :repository,
    :base_branch,
    :head_branch,
    :head_sha,
    :tests,
    :artifacts,
    :blocker,
    :occurred_at,
    :session_id,
    :workcell_id,
    :workcell_assigned?,
    :scheduler_assigned?,
    :task_id,
    :lease_id,
    :correlation_id,
    :evidence_ref,
    :decision_id,
    :origin,
    :lane
  ]

  # These are the adapter's worker-side fields. The canonical receipt uses
  # `pushed` and nests all PR/merge fields under `git`.
  @allowed_git_keys [
    :head_sha,
    :changed_files,
    :pushed?,
    :outcome,
    :merged_sha,
    :branch,
    :pr_number,
    :pr_url,
    :merge_actor_ref,
    :post_merge_evidence_ref
  ]

  @canonical_git_keys [
    :outcome,
    :pushed,
    :pr_number,
    :pr_url,
    :merged_sha,
    :merge_actor_ref,
    :post_merge_evidence_ref
  ]

  @core_keys [
    :schema_version,
    :contract,
    :kind,
    :source,
    :receipt_id,
    :idempotency_key,
    :workspace_id,
    :owner_ref,
    :runtime_id,
    :worker_id,
    :handoff_id,
    :repository,
    :base_branch,
    :head_branch,
    :head_sha,
    :release_sha,
    :changed_files,
    :tests,
    :git,
    :occurred_at,
    :redaction
  ]

  @conditional_keys [
    :session_id,
    :workcell_id,
    :task_id,
    :lease_id,
    :correlation_id,
    :evidence_ref,
    :decision_id
  ]

  @allowed_receipt_keys @core_keys ++ @conditional_keys ++ [:artifacts, :blocker]

  @doc "Build a canonical waiting/blocked Casein receipt from a trusted scope."
  @spec build(Scope.t(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def build(%Scope{} = scope, git_result, attrs)
      when is_map(git_result) and is_map(attrs) do
    with :ok <- reject_legacy_aliases(attrs),
         :ok <- reject_legacy_aliases(git_result),
         :ok <- reject_unknown_fields(attrs, @allowed_attr_keys),
         :ok <- reject_unknown_fields(git_result, @allowed_git_keys),
         {:ok, source} <- producer_source(attrs),
         :ok <- reject_dash_fields(git_result),
         :ok <- validate_git_branch(scope, git_result),
         {:ok, head_sha} <- required_sha(git_result, :head_sha, :invalid_head_sha),
         {:ok, handoff_id} <- required_scalar_id(attrs, :handoff_id, :handoff_id_required),
         {:ok, receipt_id} <- required_scalar_id(attrs, :receipt_id, :receipt_id_required),
         {:ok, identity} <- identity(scope),
         :ok <- validate_scope_attributes(scope, attrs, head_sha),
         {:ok, tests} <- normalize_tests(attrs),
         {:ok, changed_files} <- changed_files(git_result, scope),
         {:ok, artifacts} <- artifacts(attrs, scope),
         {:ok, blocker} <- blocker(attrs),
         {:ok, git} <- git_fields(git_result, source),
         {:ok, conditional} <- conditional_fields(attrs, source),
         {:ok, occurred_at} <- occurred_at(attrs) do
      receipt =
        %{
          schema_version: @schema_version,
          contract: %{name: @contract_name, version: @contract_version},
          kind: @kind,
          source: source,
          receipt_id: receipt_id,
          idempotency_key: idempotency_key(handoff_id, head_sha),
          workspace_id: identity.workspace_id,
          owner_ref: identity.owner_ref,
          runtime_id: identity.runtime_id,
          worker_id: identity.worker_id,
          handoff_id: handoff_id,
          repository: scope.repository,
          base_branch: scope.base_branch,
          head_branch: scope.assigned_branch,
          head_sha: head_sha,
          release_sha: identity.release_sha,
          changed_files: changed_files,
          tests: tests,
          git: git,
          occurred_at: occurred_at,
          redaction: redaction_marker()
        }
        |> maybe_put(:artifacts, artifacts)
        |> maybe_put(:blocker, blocker)
        |> Map.merge(conditional)

      {:ok, receipt}
    end
  end

  def build(_scope, _git_result, _attrs), do: {:error, :invalid_receipt}

  @doc "Validate a complete canonical Gate 0 receipt, including Dash documents."
  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(receipt) when is_map(receipt) do
    with :ok <- reject_unknown_fields(receipt, @allowed_receipt_keys),
         :ok <-
           exact_value(receipt, :schema_version, @schema_version, :schema_version_unsupported),
         :ok <- contract(receipt),
         :ok <- exact_value(receipt, :kind, @kind, :invalid_receipt_fields),
         {:ok, source} <- enum_value(receipt, :source, @sources, :invalid_source),
         :ok <- required_receipt_id(receipt, :receipt_id, :invalid_receipt_id),
         :ok <- required_receipt_id(receipt, :handoff_id, :invalid_handoff_id),
         :ok <- required_receipt_id(receipt, :workspace_id, :invalid_identity),
         :ok <- required_receipt_id(receipt, :runtime_id, :invalid_identity),
         :ok <- required_receipt_id(receipt, :worker_id, :invalid_identity),
         {:ok, _owner_ref} <- owner_ref(receipt),
         :ok <- required_safe_text(receipt, :repository, :invalid_receipt_fields, 512),
         :ok <- required_safe_text(receipt, :base_branch, :invalid_receipt_fields, 255),
         :ok <- required_safe_text(receipt, :head_branch, :invalid_receipt_fields, 255),
         {:ok, head_sha} <- required_sha(receipt, :head_sha, :invalid_head_sha),
         {:ok, _release_sha} <- required_sha(receipt, :release_sha, :invalid_release_sha),
         :ok <- exact_idempotency(receipt, head_sha),
         :ok <- validate_changed_files(receipt),
         :ok <- validate_receipt_tests(receipt),
         {:ok, git} <- validate_canonical_git(receipt),
         :ok <- validate_source_git(source, git),
         :ok <- validate_conditionals(receipt, source),
         :ok <- validate_occurred_at(receipt),
         :ok <- validate_redaction(receipt),
         :ok <- validate_blocker(receipt),
         :ok <- validate_artifacts(receipt) do
      :ok
    end
  end

  def validate(_receipt), do: {:error, :invalid_receipt}

  @doc "Return only canonical, redacted receipt fields."
  @spec public(map()) :: map()
  def public(receipt) when is_map(receipt) do
    receipt
    |> Map.take(@core_keys ++ @conditional_keys ++ [:artifacts, :blocker])
    |> Map.reject(fn {key, value} -> is_nil(value) and key in @conditional_keys end)
  end

  @doc "Whether a receipt is safe to send to Dash without further redaction."
  @spec valid_public?(map()) :: boolean()
  def valid_public?(receipt) when is_map(receipt) do
    public(receipt) == receipt and
      validate(receipt) == :ok and
      not Map.has_key?(receipt, :commit_sha) and
      not Map.has_key?(receipt, "commit_sha") and
      not credential_map?(receipt)
  end

  def valid_public?(_receipt), do: false

  @doc "Validate the trusted identity required before a Git handoff mutates."
  @spec validate_handoff_scope(Scope.t()) :: :ok | {:error, atom()}
  def validate_handoff_scope(%Scope{} = scope) do
    case identity(scope) do
      {:ok, _identity} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def validate_handoff_scope(_scope), do: {:error, :invalid_scope}

  @doc "Casein's handoff replay key; never use this for a review-thread action."
  @spec idempotency_key(String.t(), String.t()) :: String.t()
  def idempotency_key(handoff_id, head_sha)
      when is_binary(handoff_id) and is_binary(head_sha),
      do: "handoff:v1:" <> handoff_id <> ":" <> head_sha

  @spec idempotency_key(map()) :: String.t()
  def idempotency_key(receipt) when is_map(receipt) do
    idempotency_key(value(receipt, :handoff_id, ""), value(receipt, :head_sha, ""))
  end

  @doc "Build the independent key for one Dash review-thread action."
  @spec review_thread_action_key(String.t(), String.t(), String.t()) :: String.t()
  def review_thread_action_key(handoff_id, head_sha, thread_id)
      when is_binary(handoff_id) and is_binary(head_sha) and is_binary(thread_id),
      do: "review-thread:v1:" <> handoff_id <> ":" <> head_sha <> ":" <> thread_id

  @doc "Whether a value is an exact lowercase Git object SHA."
  @spec valid_sha?(term()) :: boolean()
  def valid_sha?(value), do: is_binary(value) and Regex.match?(@sha_re, value)

  @doc "Gate 0 schema and contract versions."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  defp identity(%Scope{} = scope) do
    values = %{
      workspace_id: scope.workspace_id,
      owner_ref: scope.owner_ref,
      runtime_id: scope.runtime_id,
      worker_id: scope.worker_id,
      release_sha: scope.release_sha
    }

    with {:ok, owner_ref} <- OwnerRef.normalize(values.owner_ref) do
      cond do
        Enum.any?([values.workspace_id, values.runtime_id, values.worker_id], &missing_string?/1) ->
          {:error, :missing_receipt_identity}

        Enum.any?([values.workspace_id, values.runtime_id, values.worker_id], &credential?/1) ->
          {:error, :credential_material}

        Enum.any?(
          [values.workspace_id, values.runtime_id, values.worker_id],
          &(not Limits.valid_scalar_id?(&1))
        ) ->
          {:error, :invalid_identity}

        not valid_sha?(values.release_sha) ->
          {:error, :invalid_release_sha}

        true ->
          {:ok, %{values | owner_ref: owner_ref}}
      end
    else
      {:error, _reason} -> {:error, :invalid_owner_ref}
    end
  end

  defp validate_scope_attributes(scope, attrs, head_sha) do
    expected = %{
      workspace_id: scope.workspace_id,
      owner_ref: scope.owner_ref,
      runtime_id: scope.runtime_id,
      worker_id: scope.worker_id,
      release_sha: scope.release_sha,
      repository: scope.repository,
      base_branch: scope.base_branch,
      head_branch: scope.assigned_branch,
      head_sha: head_sha
    }

    if Enum.all?(expected, fn {key, expected_value} ->
         case value(attrs, key) do
           nil -> true
           actual when key == :owner_ref -> OwnerRef.normalize(actual) == {:ok, expected_value}
           actual when is_binary(actual) -> actual == expected_value
           _ -> false
         end
       end) do
      :ok
    else
      # This is a static producer-side scope mismatch. `head_sha_changed` is
      # reserved for Dash's live GitHub reread race.
      {:error, :identity_mismatch}
    end
  end

  defp producer_source(attrs) do
    requested = value(attrs, :source)
    requested = requested || if(casein_terminal?(attrs), do: "v3_casein", else: "casein_worker")

    case enum_value(%{source: requested}, :source, @sources, :invalid_source) do
      {:ok, source} when source in @producer_sources -> {:ok, source}
      {:ok, _dash_verda} -> {:error, :dash_source_not_allowed}
      error -> error
    end
  end

  defp changed_files(git_result, scope) do
    case value(git_result, :changed_files, []) do
      paths when is_list(paths) ->
        cond do
          Enum.any?(paths, &(not is_binary(&1))) -> {:error, :invalid_receipt_fields}
          Enum.any?(paths, &credential?/1) -> {:error, :credential_material}
          true -> Scope.validate_paths(scope, paths)
        end

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp required_sha(source, key, error) do
    case value(source, key) do
      value when is_binary(value) ->
        if valid_sha?(value), do: {:ok, value}, else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp normalize_tests(attrs) do
    case value(attrs, :tests, []) do
      tests when is_list(tests) and length(tests) <= @max_tests ->
        Enum.reduce_while(tests, {:ok, []}, fn test, {:ok, acc} ->
          case normalize_test(test) do
            {:ok, test} -> {:cont, {:ok, [test | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, tests} -> {:ok, Enum.reverse(tests)}
          other -> other
        end

      _ ->
        {:error, :invalid_tests}
    end
  end

  defp normalize_test(command) when is_binary(command), do: normalize_test(%{command: command})

  defp normalize_test(test) when is_map(test) do
    cond do
      Map.has_key?(test, :name) or Map.has_key?(test, "name") ->
        {:error, :test_name_alias_not_allowed}

      Map.has_key?(test, :commit_sha) or Map.has_key?(test, "commit_sha") ->
        {:error, :commit_sha_not_allowed}

      reject_unknown_fields(test, [:command, :status]) != :ok ->
        {:error, :unknown_field}

      true ->
        with {:ok, command} <- required_string(test, :command, :test_command_required),
             :ok <- safe_text?(command, 500),
             {:ok, status} <- optional_text(test, :status, 100),
             :ok <- optional_status(status) do
          {:ok,
           %{command: command}
           |> maybe_put(:status, status)}
        end
    end
  end

  defp normalize_test(_test), do: {:error, :invalid_test}

  defp artifacts(attrs, scope) do
    case value(attrs, :artifacts, []) do
      values when is_list(values) and length(values) <= @max_artifacts ->
        values
        |> Enum.reduce_while({:ok, []}, fn artifact, {:ok, acc} ->
          case normalize_artifact(artifact, scope) do
            {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, values} -> {:ok, Enum.reverse(values)}
          other -> other
        end

      _ ->
        {:error, :invalid_artifacts}
    end
  end

  defp normalize_artifact(artifact, scope) when is_map(artifact) do
    path = value(artifact, :path)
    kind = value(artifact, :kind, "artifact")

    cond do
      reject_unknown_fields(artifact, [:path, :kind]) != :ok -> {:error, :unknown_field}
      not is_binary(path) -> {:error, :invalid_artifact}
      Path.type(path) == :absolute or String.contains?(path, <<0>>) -> {:error, :invalid_artifact}
      Scope.validate_path(scope, path) != :ok -> {:error, :artifact_out_of_scope}
      not is_binary(kind) or byte_size(kind) > 100 -> {:error, :invalid_artifact}
      credential?(path) or credential?(kind) -> {:error, :credential_material}
      true -> {:ok, %{path: path, kind: kind}}
    end
  end

  defp normalize_artifact(_artifact, _scope), do: {:error, :invalid_artifact}

  defp git_fields(git_result, source) do
    with {:ok, pushed?} <- required_boolean(git_result, :pushed?, :invalid_receipt_fields),
         {:ok, outcome} <- outcome(git_result, pushed?),
         :ok <- reject_worker_merge_fields(git_result, source) do
      {:ok, %{outcome: outcome, pushed: pushed?, merged_sha: nil}}
    end
  end

  defp outcome(git_result, pushed?) do
    requested = value(git_result, :outcome)

    outcome =
      case requested do
        nil -> if(pushed?, do: "waiting", else: "blocked")
        value when is_atom(value) -> Atom.to_string(value)
        value when is_binary(value) -> value
        _ -> nil
      end

    cond do
      outcome == "waiting" and pushed? -> {:ok, outcome}
      outcome in ["blocked", "failed"] -> {:ok, outcome}
      outcome == "merged" -> {:error, :worker_merge_forbidden}
      outcome == "head_sha_changed" -> {:error, :head_sha_changed_not_static}
      true -> {:error, :invalid_git_outcome}
    end
  end

  defp reject_worker_merge_fields(git_result, _source) do
    merge_fields = [:merged_sha, :merge_actor_ref, :post_merge_evidence_ref]

    if Enum.any?(merge_fields, &present?(git_result, &1)),
      do: {:error, :worker_merge_forbidden},
      else: :ok
  end

  defp reject_dash_fields(git_result) do
    if Enum.any?([:pr_number, :pr_url], &present?(git_result, &1)),
      do: {:error, :dash_git_fields_forbidden},
      else: :ok
  end

  defp validate_git_branch(scope, git_result) do
    case value(git_result, :branch) do
      nil -> :ok
      branch when branch == scope.assigned_branch -> :ok
      _ -> {:error, :identity_mismatch}
    end
  end

  defp conditional_fields(attrs, source) do
    with {:ok, session_id} <- conditional_id(attrs, :session_id, casein_terminal?(attrs)),
         {:ok, workcell_id} <- workcell_id(attrs),
         {:ok, lane_ids} <- origin_ids(attrs),
         {:ok, correlation_id} <- correlation(attrs),
         {:ok, evidence_ref} <- opaque(attrs, :evidence_ref),
         {:ok, decision_id} <- opaque(attrs, :decision_id),
         :ok <- validate_conditional_source(source, attrs, session_id, lane_ids) do
      fields =
        %{}
        |> maybe_put(:session_id, session_id)
        |> maybe_put(:workcell_id, workcell_id)
        |> Map.merge(lane_ids)
        |> maybe_put(:correlation_id, correlation_id)
        |> maybe_put(:evidence_ref, evidence_ref)
        |> maybe_put(:decision_id, decision_id)

      {:ok, fields}
    end
  end

  defp validate_conditional_source(source, attrs, session_id, lane_ids) do
    cond do
      not is_nil(session_id) and source != "v3_casein" ->
        {:error, :illegal_conditional_id}

      map_size(lane_ids) > 0 and source != "casein_worker" ->
        {:error, :illegal_origin_id}

      map_size(lane_ids) > 0 and value(attrs, :origin) not in [:mira, :oban, "mira", "oban"] ->
        {:error, :illegal_origin_id}

      true ->
        :ok
    end
  end

  defp casein_terminal?(attrs) do
    value(attrs, :lane) in [:casein_terminal, "casein_terminal", :terminal, "terminal"]
  end

  defp workcell_id(attrs) do
    case value(attrs, :workcell_id) do
      nil ->
        {:ok, nil}

      _value ->
        assigned? =
          value(attrs, :workcell_assigned?) == true or value(attrs, :scheduler_assigned?) == true

        if assigned?,
          do: conditional_id(attrs, :workcell_id, true),
          else: {:error, :workcell_not_assigned}
    end
  end

  defp conditional_id(attrs, key, allowed?) do
    case value(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) and value != "" and allowed? ->
        if Limits.valid_scalar_id?(value),
          do: {:ok, value},
          else: {:error, :illegal_conditional_id}

      _ ->
        {:error, :illegal_conditional_id}
    end
  end

  defp origin_ids(attrs) do
    task_id = value(attrs, :task_id)
    lease_id = value(attrs, :lease_id)
    origin = value(attrs, :origin)
    allowed? = origin in [:mira, :oban, "mira", "oban"]

    cond do
      is_nil(task_id) and is_nil(lease_id) ->
        {:ok, %{}}

      not allowed? ->
        {:error, :illegal_origin_id}

      is_nil(task_id) ->
        {:error, :invalid_task_id}

      not valid_optional_scalar_id?(lease_id) ->
        {:error, :invalid_lease_id}

      not mira_task_id?(task_id) ->
        {:error, :invalid_task_id}

      true ->
        {:ok, %{} |> maybe_put(:task_id, task_id) |> maybe_put(:lease_id, lease_id)}
    end
  end

  defp correlation(attrs) do
    task_id = value(attrs, :task_id)
    correlation_id = value(attrs, :correlation_id)

    cond do
      is_nil(correlation_id) -> {:ok, nil}
      is_nil(task_id) -> {:error, :illegal_origin_id}
      not safe_opaque_identifier?(correlation_id) -> {:error, :invalid_correlation_id}
      correlation_id != task_id -> {:error, :correlation_task_mismatch}
      true -> {:ok, correlation_id}
    end
  end

  defp opaque(attrs, key) do
    case value(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) and value != "" and byte_size(value) <= 256 ->
        if credential?(value), do: {:error, :credential_material}, else: {:ok, value}

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp occurred_at(attrs) do
    case value(attrs, :occurred_at) do
      nil ->
        {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}

      %DateTime{} = value ->
        {:ok, DateTime.to_iso8601(value)}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, date_time, _offset} -> {:ok, DateTime.to_iso8601(date_time)}
          _ -> {:error, :invalid_occurred_at}
        end

      _ ->
        {:error, :invalid_occurred_at}
    end
  end

  defp blocker(attrs) do
    case value(attrs, :blocker) do
      nil ->
        {:ok, nil}

      blocker when is_binary(blocker) and byte_size(blocker) <= 500 ->
        if credential?(blocker),
          do: {:error, :credential_material},
          else: {:ok, String.trim(blocker)}

      _ ->
        {:error, :invalid_blocker}
    end
  end

  defp required_string(attrs, key, error) do
    case value(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error}
          value -> if credential?(value), do: {:error, :credential_material}, else: {:ok, value}
        end

      _ ->
        {:error, error}
    end
  end

  defp required_scalar_id(attrs, key, error) do
    with {:ok, value} <- required_string(attrs, key, error) do
      if Limits.valid_scalar_id?(value),
        do: {:ok, value},
        else: {:error, invalid_id_error(key)}
    end
  end

  defp invalid_id_error(:handoff_id), do: :invalid_handoff_id
  defp invalid_id_error(:receipt_id), do: :invalid_receipt_id
  defp invalid_id_error(_key), do: :invalid_receipt_fields

  defp optional_text(attrs, key, max) do
    case value(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if byte_size(value) <= max and not credential?(value),
          do: {:ok, String.trim(value)},
          else: {:error, :invalid_test}

      _ ->
        {:error, :invalid_test}
    end
  end

  defp optional_status(nil), do: :ok
  defp optional_status(status) when status in ["passed", "failed", "skipped"], do: :ok
  defp optional_status(_status), do: {:error, :invalid_test}

  defp safe_text?(value, max) when is_binary(value) do
    if byte_size(value) <= max and not credential?(value),
      do: :ok,
      else: {:error, :invalid_receipt_fields}
  end

  defp required_boolean(source, key, error) do
    case value(source, key, :missing) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp reject_legacy_aliases(source) do
    if Map.has_key?(source, :commit_sha) or Map.has_key?(source, "commit_sha"),
      do: {:error, :commit_sha_not_allowed},
      else: :ok
  end

  defp reject_unknown_fields(map, allowed) when is_map(map) do
    allowed_strings = Enum.map(allowed, &Atom.to_string/1)

    if Enum.all?(Map.keys(map), fn
         key when is_atom(key) -> key in allowed
         key when is_binary(key) -> key in allowed_strings
         _key -> false
       end),
       do: :ok,
       else: {:error, :unknown_field}
  end

  defp redaction_marker do
    %{applied: true, omitted: ["credentials", "secrets", "raw_output"]}
  end

  defp credential_map?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      credential?(to_string(key)) or credential?(item) or credential_map?(item)
    end)
  end

  defp credential_map?(value) when is_list(value), do: Enum.any?(value, &credential_map?/1)
  defp credential_map?(_value), do: false

  defp valid_non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_optional_scalar_id?(nil), do: true
  defp valid_optional_scalar_id?(value), do: Limits.valid_scalar_id?(value)

  defp safe_opaque_identifier?(value) do
    valid_non_empty_string?(value) and byte_size(value) <= 256 and
      not String.contains?(value, <<0>>) and not String.contains?(value, "\n") and
      not credential?(value)
  end

  defp mira_task_id?(value) do
    is_binary(value) and
      Regex.match?(
        ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
        value
      ) and
      Ecto.UUID.cast(value) == {:ok, value}
  end

  defp missing_string?(value), do: not valid_non_empty_string?(value)
  defp present?(map, key), do: not is_nil(value(map, key))

  defp credential?(value) when is_binary(value) do
    Regex.match?(
      ~r/(?:bearer\s+|password\s*=|token\s*=|api[_-]?key\s*=|gh[pousr]_|xox[baprs]-|-----begin .* private key)/i,
      value
    )
  end

  defp credential?(_value), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp enum_value(attrs, key, allowed, error) do
    case value(attrs, key) do
      value when is_atom(value) ->
        value = Atom.to_string(value)
        if value in allowed, do: {:ok, value}, else: {:error, error}

      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp exact_value(attrs, key, expected, error) do
    if value(attrs, key) == expected, do: :ok, else: {:error, error}
  end

  defp contract(receipt) do
    contract = value(receipt, :contract)

    if is_map(contract) and
         reject_unknown_fields(contract, [:name, :version]) == :ok and
         value(contract, :name) == @contract_name and
         value(contract, :version) == @contract_version,
       do: :ok,
       else: {:error, :contract_version_unsupported}
  end

  defp required_receipt_id(receipt, key, error) do
    case value(receipt, key) do
      value when is_binary(value) ->
        if Limits.valid_scalar_id?(value), do: :ok, else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp owner_ref(receipt) do
    case OwnerRef.normalize(value(receipt, :owner_ref)) do
      {:ok, owner_ref} -> {:ok, owner_ref}
      {:error, _reason} -> {:error, :invalid_owner_ref}
    end
  end

  defp required_safe_text(attrs, key, error, max) do
    case value(attrs, key) do
      value when is_binary(value) ->
        if valid_non_empty_string?(value) and byte_size(value) <= max and not credential?(value),
          do: :ok,
          else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp exact_idempotency(receipt, head_sha) do
    handoff_id = value(receipt, :handoff_id)
    expected = idempotency_key(handoff_id, head_sha)

    if value(receipt, :idempotency_key) == expected,
      do: :ok,
      else: {:error, :idempotency_mismatch}
  end

  defp validate_changed_files(receipt) do
    case value(receipt, :changed_files) do
      paths when is_list(paths) ->
        if Enum.all?(paths, &valid_public_path?/1),
          do: :ok,
          else: {:error, :invalid_receipt_fields}

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp valid_public_path?(path) when is_binary(path) do
    path != "" and byte_size(path) <= 512 and Path.type(path) != :absolute and
      not String.contains?(path, <<0>>) and not String.contains?(path, "\\") and
      Enum.all?(Path.split(path), &(&1 not in ["..", ".git"])) and not credential?(path)
  end

  defp valid_public_path?(_path), do: false

  defp validate_receipt_tests(receipt) do
    case normalize_tests(%{tests: value(receipt, :tests)}) do
      {:ok, tests} ->
        incoming = value(receipt, :tests)

        canonical_incoming =
          Enum.map(incoming, fn test ->
            case normalize_test(test) do
              {:ok, normalized} -> normalized
              _ -> :invalid
            end
          end)

        if tests == canonical_incoming, do: :ok, else: {:error, :invalid_receipt_fields}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_canonical_git(receipt) do
    git = value(receipt, :git)

    with true <- is_map(git),
         :ok <- reject_unknown_fields(git, @canonical_git_keys),
         {:ok, pushed} <- canonical_boolean(git, :pushed),
         {:ok, outcome} <- canonical_outcome(git),
         :ok <- canonical_outcome_pushed(outcome, pushed),
         {:ok, merged_sha} <- canonical_merged_sha(git, outcome),
         {:ok, merge_actor_ref} <- canonical_actor_ref(git, :merge_actor_ref),
         {:ok, post_merge_evidence_ref} <- canonical_opaque(git, :post_merge_evidence_ref),
         :ok <- canonical_pr(git) do
      {:ok,
       %{
         outcome: outcome,
         pushed: pushed,
         pr_number: value(git, :pr_number),
         pr_url: value(git, :pr_url),
         merged_sha: merged_sha,
         merge_actor_ref: merge_actor_ref,
         post_merge_evidence_ref: post_merge_evidence_ref
       }}
    else
      false -> {:error, :invalid_git_outcome}
      {:error, _reason} = error -> error
    end
  end

  defp canonical_boolean(git, key) do
    case value(git, key, :missing) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_receipt_fields}
    end
  end

  defp canonical_outcome_pushed("waiting", true), do: :ok
  defp canonical_outcome_pushed("waiting", false), do: {:error, :invalid_git_outcome}
  defp canonical_outcome_pushed("merged", true), do: :ok
  defp canonical_outcome_pushed(_outcome, _pushed), do: :ok

  defp canonical_outcome(git) do
    case value(git, :outcome) do
      outcome when outcome in ["waiting", "blocked", "failed", "head_sha_changed", "merged"] ->
        {:ok, outcome}

      outcome when is_atom(outcome) ->
        canonical_outcome(Map.put(git, :outcome, Atom.to_string(outcome)))

      _ ->
        {:error, :invalid_git_outcome}
    end
  end

  defp canonical_merged_sha(git, "merged") do
    case value(git, :merged_sha) do
      value when is_binary(value) ->
        if valid_sha?(value), do: {:ok, value}, else: {:error, :invalid_merged_sha}

      _ ->
        {:error, :merged_sha_required}
    end
  end

  defp canonical_merged_sha(git, _outcome) do
    case value(git, :merged_sha) do
      nil -> {:ok, nil}
      _ -> {:error, :merged_sha_not_allowed}
    end
  end

  defp canonical_actor_ref(git, key) do
    case value(git, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Regex.match?(~r/\A[a-z0-9._-]+\/[a-z0-9._-]+\z/, value),
          do: {:ok, value},
          else: {:error, :invalid_merge_actor_ref}

      _value ->
        {:error, :invalid_merge_actor_ref}
    end
  end

  defp canonical_opaque(git, key) do
    case value(git, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if safe_opaque_identifier?(value),
          do: {:ok, value},
          else: {:error, :invalid_receipt_fields}

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp canonical_pr(git) do
    with :ok <- optional_positive_integer(git, :pr_number),
         :ok <- optional_url(git, :pr_url) do
      :ok
    end
  end

  defp optional_positive_integer(git, key) do
    case value(git, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _ -> {:error, :invalid_receipt_fields}
    end
  end

  defp optional_url(git, key) do
    case value(git, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        cond do
          byte_size(value) > 2_048 or not valid_non_empty_string?(value) or
              not String.starts_with?(value, "https://") ->
            {:error, :invalid_receipt_fields}

          credential?(value) ->
            {:error, :credential_material}

          true ->
            :ok
        end

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp validate_source_git("dash_verda", git) do
    cond do
      git.outcome != "merged" ->
        {:error, :invalid_source_outcome}

      git.outcome == "merged" and is_nil(git.merged_sha) ->
        {:error, :merged_sha_required}

      git.outcome == "merged" and is_nil(git.merge_actor_ref) ->
        {:error, :merge_actor_ref_required}

      git.outcome == "merged" and is_nil(git.post_merge_evidence_ref) ->
        {:error, :post_merge_evidence_required}

      git.outcome == "merged" and is_nil(value(git, :pr_number)) ->
        {:error, :pr_number_required}

      git.outcome == "merged" and is_nil(value(git, :pr_url)) ->
        {:error, :pr_url_required}

      true ->
        :ok
    end
  end

  defp validate_source_git(source, git) when source in @producer_sources do
    cond do
      git.outcome == "merged" ->
        {:error, :worker_merge_forbidden}

      git.outcome == "head_sha_changed" ->
        {:error, :head_sha_changed_not_static}

      present?(git, :pr_number) or present?(git, :pr_url) or not is_nil(git.merge_actor_ref) or
          not is_nil(git.post_merge_evidence_ref) ->
        {:error, :dash_git_fields_forbidden}

      true ->
        :ok
    end
  end

  defp validate_conditionals(receipt, source) do
    with :ok <- optional_receipt_id(receipt, :session_id),
         :ok <- optional_receipt_id(receipt, :workcell_id),
         :ok <- optional_receipt_id(receipt, :lease_id),
         :ok <- optional_task_id(receipt),
         :ok <- optional_opaque(receipt, :correlation_id),
         :ok <- optional_opaque(receipt, :evidence_ref),
         :ok <- optional_opaque(receipt, :decision_id) do
      task_id = value(receipt, :task_id)
      lease_id = value(receipt, :lease_id)
      correlation_id = value(receipt, :correlation_id)

      cond do
        is_nil(task_id) and (not is_nil(lease_id) or not is_nil(correlation_id)) ->
          {:error, :illegal_origin_id}

        not is_nil(task_id) and not mira_task_id?(task_id) ->
          {:error, :invalid_task_id}

        not is_nil(task_id) and is_nil(lease_id) ->
          {:error, :invalid_lease_id}

        correlation_id != task_id ->
          {:error, :correlation_task_mismatch}

        source == "v3_casein" and not is_nil(task_id) ->
          {:error, :illegal_origin_id}

        value(receipt, :session_id) != nil and source != "v3_casein" ->
          {:error, :illegal_conditional_id}

        true ->
          :ok
      end
    end
  end

  defp optional_receipt_id(receipt, key) do
    case value(receipt, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        if Limits.valid_scalar_id?(value), do: :ok, else: {:error, :illegal_conditional_id}

      _ ->
        {:error, :illegal_conditional_id}
    end
  end

  defp optional_task_id(receipt) do
    case value(receipt, :task_id) do
      nil ->
        :ok

      value when is_binary(value) ->
        if mira_task_id?(value), do: :ok, else: {:error, :invalid_task_id}

      _ ->
        {:error, :invalid_task_id}
    end
  end

  defp optional_opaque(receipt, key) do
    case value(receipt, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        if safe_opaque_identifier?(value), do: :ok, else: {:error, :invalid_receipt_fields}

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp validate_occurred_at(receipt) do
    case value(receipt, :occurred_at) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _date_time, _offset} -> :ok
          _ -> {:error, :invalid_occurred_at}
        end

      _ ->
        {:error, :invalid_occurred_at}
    end
  end

  defp validate_redaction(receipt) do
    case value(receipt, :redaction) do
      %{applied: true, omitted: omitted} when is_list(omitted) -> :ok
      %{"applied" => true, "omitted" => omitted} when is_list(omitted) -> :ok
      _ -> {:error, :redaction_required}
    end
  end

  defp validate_blocker(receipt) do
    case value(receipt, :blocker) do
      nil ->
        :ok

      blocker when is_binary(blocker) ->
        if byte_size(blocker) <= 500 and not credential?(blocker),
          do: :ok,
          else: {:error, :invalid_blocker}

      _ ->
        {:error, :invalid_blocker}
    end
  end

  defp validate_artifacts(receipt) do
    case value(receipt, :artifacts) do
      nil ->
        :ok

      artifacts when is_list(artifacts) and length(artifacts) <= @max_artifacts ->
        if Enum.all?(artifacts, fn artifact ->
             is_map(artifact) and reject_unknown_fields(artifact, [:path, :kind]) == :ok and
               valid_public_path?(value(artifact, :path)) and
               is_binary(value(artifact, :kind)) and not credential_map?(artifact)
           end),
           do: :ok,
           else: {:error, :invalid_artifacts}

      _ ->
        {:error, :invalid_artifacts}
    end
  end
end
