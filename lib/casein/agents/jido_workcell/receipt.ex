defmodule Casein.Agents.JidoWorkcell.Receipt do
  @moduledoc """
  Strict, redacted completion receipt shared with Dash.

  Casein emits only a waiting handoff receipt. Dash/Verda owns live PR, CI,
  review-thread, approval, merge, and deploy operations. The wire shape here
  is the frozen Gate 0 shape; adapter-local names never cross that boundary.
  """

  alias Casein.Agents.JidoWorkcell.Git.Scope
  alias Casein.Agents.JidoWorkcell.{Limits, OwnerRef}

  @schema_version 1
  @contract_name "casein-dash-handoff"
  @contract_version "1.0"
  @sources ~w(v3_casein casein_worker dash_verda)
  @producer_sources ~w(v3_casein casein_worker)
  @git_outcomes ~w(waiting blocked merged head_sha_changed failed)
  @authorization_decisions ~w(allow deny hold revoke)
  @sha_re ~r/\A[0-9a-f]{40}\z/
  @max_tests Limits.max_tests()
  @max_files Limits.max_paths()

  # These are the only keys that may appear on the Gate 0 receipt. In
  # particular, implementation metadata such as kind, occurred_at, redaction,
  # artifacts, and top-level Git fields must not leak into the handoff.
  @wire_keys [
    :schema_version,
    :contract,
    :receipt_id,
    :request_id,
    :source,
    :handoff_id,
    :workspace_id,
    :owner_ref,
    :runtime_id,
    :worker_id,
    :session_id,
    :workcell_id,
    :task_id,
    :lease_id,
    :correlation_id,
    :authorization,
    :evidence_ref,
    :idempotency,
    :git,
    :tests,
    :files
  ]

  @git_keys [
    :repository,
    :base_branch,
    :head_branch,
    :head_sha,
    :release_sha,
    :pr_number,
    :pr_url,
    :outcome,
    :merged_sha,
    :merge_actor_ref,
    :post_merge_evidence_ref
  ]

  @authorization_keys [:decision, :decision_id]
  @idempotency_keys [:handoff_key]
  @test_keys [:command, :status]
  @file_keys [:path]

  # Adapter input is intentionally separate from the wire keys. `pushed?`,
  # `changed_files`, and `branch` are local facts used to build the receipt;
  # none of them is serialized under its local name.
  @allowed_attr_keys [
    :paths,
    :message,
    :source,
    :receipt_id,
    :request_id,
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
    :session_id,
    :workcell_id,
    :workcell_assigned?,
    :scheduler_assigned?,
    :task_id,
    :lease_id,
    :correlation_id,
    :evidence_ref,
    :decision_id,
    :authorization,
    :origin,
    :lane
  ]

  @allowed_git_input_keys [
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

  @doc "Build a frozen Gate 0 waiting receipt from a trusted scope."
  @spec build(Scope.t(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def build(%Scope{} = scope, git_result, attrs)
      when is_map(git_result) and is_map(attrs) do
    with :ok <- reject_legacy_aliases(attrs),
         :ok <- reject_legacy_aliases(git_result),
         :ok <- reject_unknown_fields(attrs, @allowed_attr_keys),
         :ok <- reject_unknown_fields(git_result, @allowed_git_input_keys),
         {:ok, source} <- producer_source(attrs),
         :ok <- reject_dash_fields(git_result),
         :ok <- validate_git_branch(scope, git_result),
         {:ok, head_sha} <- required_sha(git_result, :head_sha, :invalid_head_sha),
         {:ok, request_id} <- required_scalar_id(attrs, :request_id, :request_id_required),
         {:ok, handoff_id} <- required_scalar_id(attrs, :handoff_id, :handoff_id_required),
         {:ok, receipt_id} <- required_scalar_id(attrs, :receipt_id, :receipt_id_required),
         {:ok, session_id} <- required_scalar_id(attrs, :session_id, :session_id_required),
         {:ok, workcell_id} <- assigned_workcell_id(attrs),
         {:ok, identity} <- identity(scope),
         :ok <- validate_scope_attributes(scope, attrs, head_sha),
         {:ok, authorization} <- authorization(attrs),
         {:ok, tests} <- normalize_tests(attrs),
         {:ok, files} <- changed_files(git_result, scope),
         {:ok, git} <- git_fields(scope, git_result, source, head_sha),
         {:ok, conditional} <- conditional_fields(attrs, source) do
      receipt =
        %{
          schema_version: @schema_version,
          contract: %{name: @contract_name, version: @contract_version},
          receipt_id: receipt_id,
          request_id: request_id,
          source: source,
          handoff_id: handoff_id,
          workspace_id: identity.workspace_id,
          owner_ref: identity.owner_ref,
          runtime_id: identity.runtime_id,
          worker_id: identity.worker_id,
          session_id: session_id,
          workcell_id: workcell_id,
          authorization: authorization,
          idempotency: %{handoff_key: idempotency_key(handoff_id, head_sha)},
          git: git,
          tests: tests
        }
        |> maybe_put(:files, files)
        |> maybe_put(:evidence_ref, optional_wire_opaque(attrs, :evidence_ref))
        |> Map.merge(conditional)

      case validate(receipt) do
        :ok -> {:ok, receipt}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def build(_scope, _git_result, _attrs), do: {:error, :invalid_receipt}

  @doc "Validate a frozen Gate 0 receipt, including Dash merged documents."
  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(receipt) when is_map(receipt), do: validate(receipt, nil)

  @doc "Validate a receipt against trusted static identity when available."
  @spec validate(map(), map() | nil) :: :ok | {:error, atom()}
  def validate(receipt, static_identity)

  def validate(receipt, static_identity)
      when is_map(receipt) and (is_map(static_identity) or is_nil(static_identity)) do
    with :ok <- reject_forbidden_aliases(receipt),
         :ok <- reject_unknown_fields(receipt, @wire_keys),
         :ok <-
           exact_value(receipt, :schema_version, @schema_version, :schema_version_unsupported),
         :ok <- contract(receipt),
         {:ok, source} <- enum_value(receipt, :source, @sources, :invalid_source),
         :ok <- required_receipt_id(receipt, :receipt_id, :missing_id),
         :ok <- required_receipt_id(receipt, :request_id, :missing_id),
         :ok <- required_receipt_id(receipt, :handoff_id, :missing_id),
         :ok <- required_workspace_id(receipt),
         :ok <- required_receipt_id(receipt, :runtime_id, :missing_id),
         :ok <- required_receipt_id(receipt, :worker_id, :missing_id),
         {:ok, _owner_ref} <- owner_ref(receipt),
         :ok <- validate_lane_fields(receipt, source),
         {:ok, _authorization} <- validate_authorization(receipt),
         :ok <- validate_source_outcome(receipt, source),
         {:ok, git} <- validate_git(receipt),
         :ok <- validate_source_git(source, git),
         :ok <- validate_static_identity(source, git, static_identity),
         :ok <- validate_idempotency(receipt, git.head_sha),
         :ok <- validate_tests(receipt),
         :ok <- validate_files(receipt),
         :ok <- validate_evidence(receipt) do
      if credential_map?(receipt), do: {:error, :credential_material}, else: :ok
    end
  end

  def validate(_receipt, _static_identity), do: {:error, :invalid_receipt}

  @doc "Return only canonical, redacted receipt fields."
  @spec public(map()) :: map()
  def public(receipt) when is_map(receipt) do
    receipt
    |> Map.take(@wire_keys)
    |> Map.reject(fn {key, value} -> is_nil(value) and key in optional_wire_keys() end)
  end

  @doc "Whether a receipt is safe to send to Dash without further redaction."
  @spec valid_public?(map()) :: boolean()
  def valid_public?(receipt) when is_map(receipt) do
    public(receipt) == receipt and validate(receipt) == :ok and not credential_map?(receipt)
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
    idempotency_key(value(receipt, :handoff_id, ""), head_sha(receipt, ""))
  end

  @spec head_sha(map(), term()) :: term()
  def head_sha(receipt, default \\ nil)

  def head_sha(receipt, default) when is_map(receipt) do
    value(value(receipt, :git, %{}), :head_sha, value(receipt, :head_sha, default))
  end

  def head_sha(_receipt, default), do: default

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

  defp optional_wire_keys do
    [:session_id, :workcell_id, :task_id, :lease_id, :correlation_id, :evidence_ref, :files]
  end

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
        foreign_workspace_id?(values.workspace_id) ->
          {:error, :foreign_lane_id}

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
      # Static producer drift is not the live GitHub reread race.
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

  defp assigned_workcell_id(attrs) do
    assigned? =
      value(attrs, :workcell_assigned?) == true or value(attrs, :scheduler_assigned?) == true

    case value(attrs, :workcell_id) do
      value when is_binary(value) and assigned? ->
        if Limits.valid_scalar_id?(value),
          do: {:ok, value},
          else: {:error, :illegal_conditional_id}

      nil ->
        {:error, :workcell_id_required}

      _ ->
        {:error, :workcell_not_assigned}
    end
  end

  defp casein_terminal?(attrs) do
    value(attrs, :lane) in [:casein_terminal, "casein_terminal", :terminal, "terminal"]
  end

  defp changed_files(git_result, scope) do
    case value(git_result, :changed_files, []) do
      paths when is_list(paths) ->
        cond do
          Enum.any?(paths, &(not is_binary(&1))) ->
            {:error, :invalid_receipt_fields}

          Enum.any?(paths, &credential?/1) ->
            {:error, :credential_material}

          true ->
            with {:ok, paths} <- Scope.validate_paths(scope, paths) do
              {:ok, Enum.map(paths, &%{path: &1})}
            end
        end

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp git_fields(scope, git_result, _source, head_sha) do
    with {:ok, pushed?} <- required_boolean(git_result, :pushed?, :invalid_receipt_fields),
         {:ok, outcome} <- outcome(git_result, pushed?),
         :ok <- reject_worker_merge_fields(git_result),
         :ok <- reject_dash_fields(git_result) do
      {:ok,
       %{
         repository: scope.repository,
         base_branch: scope.base_branch,
         head_branch: scope.assigned_branch,
         head_sha: head_sha,
         release_sha: scope.release_sha,
         outcome: outcome,
         merged_sha: nil,
         merge_actor_ref: nil,
         post_merge_evidence_ref: nil
       }}
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

  defp reject_worker_merge_fields(git_result) do
    if Enum.any?(
         [:merged_sha, :merge_actor_ref, :post_merge_evidence_ref],
         &present?(git_result, &1)
       ),
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

      reject_unknown_fields(test, @test_keys) != :ok ->
        {:error, :unknown_field}

      true ->
        with {:ok, command} <- required_string(test, :command, :test_command_required),
             :ok <- safe_text?(command, 500),
             {:ok, status} <- optional_test_status(test) do
          {:ok, %{command: command} |> maybe_put(:status, status)}
        end
    end
  end

  defp normalize_test(_test), do: {:error, :invalid_test}

  defp optional_test_status(test) do
    case value(test, :status) do
      nil -> {:ok, nil}
      status when status in ["passed", "failed", "skipped"] -> {:ok, status}
      _ -> {:error, :invalid_test}
    end
  end

  defp conditional_fields(attrs, source) do
    with {:ok, lane_ids} <- origin_ids(attrs),
         {:ok, correlation_id} <- correlation(attrs),
         {:ok, evidence_ref} <- opaque(attrs, :evidence_ref),
         :ok <- validate_conditional_source(source, attrs, lane_ids) do
      fields =
        %{}
        |> Map.merge(lane_ids)
        |> maybe_put(:correlation_id, correlation_id)
        |> maybe_put(:evidence_ref, evidence_ref)

      {:ok, fields}
    end
  end

  defp validate_conditional_source(source, attrs, lane_ids) do
    cond do
      map_size(lane_ids) > 0 and source != "casein_worker" ->
        {:error, :illegal_origin_id}

      map_size(lane_ids) > 0 and value(attrs, :origin) not in [:mira, :oban, "mira", "oban"] ->
        {:error, :illegal_origin_id}

      true ->
        :ok
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
        {:ok, %{task_id: task_id, lease_id: lease_id}}
    end
  end

  defp correlation(attrs) do
    task_id = value(attrs, :task_id)
    correlation_id = value(attrs, :correlation_id)

    cond do
      is_nil(correlation_id) ->
        {:ok, nil}

      is_nil(task_id) ->
        {:error, :illegal_origin_id}

      not safe_opaque_identifier?(correlation_id) ->
        {:error, :invalid_correlation_id}

      correlation_id != task_id ->
        {:error, :correlation_task_mismatch}

      true ->
        {:ok, correlation_id}
    end
  end

  defp authorization(attrs) do
    case value(attrs, :authorization) do
      authorization when is_map(authorization) ->
        with {:ok, normalized} <- normalize_authorization(authorization),
             :ok <- authorization_alias_matches(attrs, normalized) do
          {:ok, normalized}
        end

      _ ->
        {:error, :authorization_required}
    end
  end

  defp normalize_authorization(authorization) do
    with :ok <- reject_unknown_fields(authorization, @authorization_keys),
         {:ok, decision} <-
           enum_value(
             authorization,
             :decision,
             @authorization_decisions,
             :invalid_authorization_decision
           ),
         {:ok, decision_id} <-
           required_opaque(authorization, :decision_id, :authorization_decision_id_required) do
      {:ok, %{decision: decision, decision_id: decision_id}}
    end
  end

  defp authorization_alias_matches(attrs, authorization) do
    case value(attrs, :decision_id) do
      nil -> :ok
      value when value == authorization.decision_id -> :ok
      _ -> {:error, :authorization_mismatch}
    end
  end

  defp optional_wire_opaque(attrs, key) do
    case value(attrs, key) do
      nil -> nil
      value -> if safe_opaque_identifier?(value), do: value, else: nil
    end
  end

  defp opaque(attrs, key) do
    case value(attrs, key) do
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

  defp required_opaque(attrs, key, error) do
    case value(attrs, key) do
      value when is_binary(value) ->
        if safe_opaque_identifier?(value), do: {:ok, value}, else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp validate_lane_fields(receipt, source) do
    with :ok <- optional_receipt_id(receipt, :session_id),
         :ok <- optional_receipt_id(receipt, :workcell_id),
         :ok <- optional_receipt_id(receipt, :lease_id),
         :ok <- optional_task_id(receipt),
         :ok <- optional_opaque(receipt, :correlation_id) do
      task_id = value(receipt, :task_id)
      lease_id = value(receipt, :lease_id)
      correlation_id = value(receipt, :correlation_id)

      cond do
        source in @producer_sources and is_nil(value(receipt, :session_id)) ->
          {:error, :missing_id}

        source in @producer_sources and is_nil(value(receipt, :workcell_id)) ->
          {:error, :missing_id}

        is_nil(task_id) and (not is_nil(lease_id) or not is_nil(correlation_id)) and
            source in ["casein_worker", "dash_verda"] ->
          {:error, :missing_id}

        is_nil(task_id) and (not is_nil(lease_id) or not is_nil(correlation_id)) ->
          {:error, :foreign_lane_id}

        not is_nil(task_id) and source not in ["casein_worker", "dash_verda"] ->
          {:error, :foreign_lane_id}

        not is_nil(task_id) and is_nil(lease_id) ->
          {:error, :missing_id}

        not is_nil(task_id) and is_nil(correlation_id) ->
          {:error, :missing_id}

        not is_nil(task_id) and correlation_id != task_id ->
          {:error, :correlation_mismatch}

        true ->
          :ok
      end
    end
  end

  defp validate_authorization(receipt) do
    case value(receipt, :authorization) do
      authorization when is_map(authorization) -> normalize_authorization(authorization)
      _ -> {:error, :missing_authorization}
    end
  end

  defp validate_git(receipt) do
    git = value(receipt, :git)

    with true <- is_map(git),
         :ok <- reject_unknown_fields(git, @git_keys),
         {:ok, repository} <- required_safe_text(git, :repository, :invalid_repository, 512),
         {:ok, base_branch} <- required_safe_text(git, :base_branch, :invalid_branch, 255),
         {:ok, head_branch} <- required_safe_text(git, :head_branch, :invalid_branch, 255),
         {:ok, head_sha} <- required_sha(git, :head_sha, :invalid_sha),
         {:ok, release_sha} <- required_sha(git, :release_sha, :invalid_sha),
         {:ok, outcome} <- canonical_outcome(git),
         :ok <- optional_pr(git),
         {:ok, merged_sha} <- canonical_merged_sha(git, outcome),
         {:ok, merge_actor_ref} <- canonical_actor_ref(git),
         {:ok, post_merge_evidence_ref} <- canonical_post_merge_evidence(git, outcome) do
      {:ok,
       %{
         repository: repository,
         base_branch: base_branch,
         head_branch: head_branch,
         head_sha: head_sha,
         release_sha: release_sha,
         pr_number: value(git, :pr_number),
         pr_url: value(git, :pr_url),
         outcome: outcome,
         merged_sha: merged_sha,
         merge_actor_ref: merge_actor_ref,
         post_merge_evidence_ref: post_merge_evidence_ref
       }}
    else
      false -> {:error, :invalid_git_outcome}
      {:error, _reason} = error -> error
    end
  end

  defp validate_source_outcome(receipt, source) do
    case value(receipt, :git) do
      git when is_map(git) ->
        case canonical_outcome(git) do
          {:ok, "waiting"} when source in @producer_sources -> :ok
          {:ok, "merged"} when source == "dash_verda" -> :ok
          {:ok, _outcome} -> {:error, :invalid_source_outcome}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, :invalid_git_outcome}
    end
  end

  defp canonical_outcome(git) do
    case value(git, :outcome) do
      outcome when outcome in @git_outcomes -> {:ok, outcome}
      _ -> {:error, :invalid_git_outcome}
    end
  end

  defp optional_pr(git) do
    with :ok <- optional_positive_integer(git, :pr_number),
         :ok <- optional_url(git, :pr_url) do
      :ok
    end
  end

  defp canonical_merged_sha(git, "merged") do
    case value(git, :merged_sha, :missing) do
      value when is_binary(value) ->
        if valid_sha?(value), do: {:ok, value}, else: {:error, :invalid_sha}

      :missing ->
        {:error, :merged_sha_required}

      _ ->
        {:error, :merged_sha_required}
    end
  end

  defp canonical_merged_sha(git, _outcome) do
    case value(git, :merged_sha, nil) do
      nil -> {:ok, nil}
      _ -> {:error, :merged_sha_not_allowed}
    end
  end

  defp canonical_actor_ref(git) do
    case value(git, :merge_actor_ref, nil) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Regex.match?(~r/\A[a-z0-9._-]+\/[a-z0-9._-]+\z/, value),
          do: {:ok, value},
          else: {:error, :invalid_actor_ref}

      _ ->
        {:error, :invalid_actor_ref}
    end
  end

  defp canonical_post_merge_evidence(git, "merged") do
    case value(git, :post_merge_evidence_ref, nil) do
      value when is_binary(value) ->
        if safe_opaque_identifier?(value),
          do: {:ok, value},
          else: {:error, :invalid_receipt_fields}

      _ ->
        {:error, :post_merge_evidence_required}
    end
  end

  defp canonical_post_merge_evidence(git, _outcome) do
    case value(git, :post_merge_evidence_ref, nil) do
      nil -> {:ok, nil}
      _ -> {:error, :post_merge_evidence_not_allowed}
    end
  end

  defp validate_source_git("dash_verda", git) do
    cond do
      git.outcome != "merged" -> {:error, :invalid_source_outcome}
      is_nil(git.merged_sha) -> {:error, :merged_sha_required}
      is_nil(git.merge_actor_ref) -> {:error, :merge_actor_required}
      is_nil(git.post_merge_evidence_ref) -> {:error, :post_merge_evidence_required}
      is_nil(git.pr_number) -> {:error, :pr_number_required}
      is_nil(git.pr_url) -> {:error, :pr_url_required}
      true -> :ok
    end
  end

  defp validate_source_git(source, git) when source in @producer_sources do
    cond do
      git.outcome != "waiting" -> {:error, :invalid_source_outcome}
      not is_nil(git.merged_sha) -> {:error, :merged_sha_not_allowed}
      not is_nil(git.merge_actor_ref) -> {:error, :dash_git_fields_forbidden}
      not is_nil(git.post_merge_evidence_ref) -> {:error, :post_merge_evidence_not_allowed}
      true -> :ok
    end
  end

  defp validate_static_identity(_source, _git, nil), do: :ok

  defp validate_static_identity("dash_verda", git, expected) when is_map(expected) do
    if Enum.all?([:repository, :pr_number, :head_sha], fn key ->
         case value(expected, key) do
           nil -> true
           expected_value -> value(git, key) == expected_value
         end
       end),
       do: :ok,
       else: {:error, :invalid_dash_identity}
  end

  defp validate_static_identity(_source, _git, _expected), do: :ok

  defp validate_idempotency(receipt, head_sha) do
    case value(receipt, :idempotency) do
      idempotency when is_map(idempotency) ->
        with :ok <- reject_unknown_fields(idempotency, @idempotency_keys),
             {:ok, handoff_key} <-
               required_string(idempotency, :handoff_key, :idempotency_mismatch) do
          cond do
            String.starts_with?(handoff_key, "review-thread:v1:") ->
              {:error, :idempotency_namespace_mismatch}

            handoff_key == idempotency_key(value(receipt, :handoff_id), head_sha) ->
              :ok

            true ->
              {:error, :idempotency_mismatch}
          end
        end

      _ ->
        {:error, :idempotency_mismatch}
    end
  end

  defp validate_tests(receipt) do
    case value(receipt, :tests) do
      tests when is_list(tests) and length(tests) <= @max_tests ->
        Enum.reduce_while(tests, :ok, fn test, :ok ->
          case normalize_test(test) do
            {:ok, _canonical} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      _ ->
        {:error, :invalid_tests}
    end
  end

  defp validate_files(receipt) do
    case value(receipt, :files) do
      nil ->
        :ok

      files when is_list(files) and length(files) <= @max_files ->
        if Enum.all?(files, &valid_file?/1), do: :ok, else: {:error, :absolute_path_forbidden}

      _ ->
        {:error, :invalid_files}
    end
  end

  defp valid_file?(file) when is_map(file) do
    reject_unknown_fields(file, @file_keys) == :ok and valid_public_path?(value(file, :path))
  end

  defp valid_file?(_file), do: false

  defp validate_evidence(receipt) do
    case value(receipt, :evidence_ref) do
      nil ->
        :ok

      value when is_binary(value) ->
        if safe_opaque_identifier?(value), do: :ok, else: {:error, :invalid_receipt_fields}

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp optional_receipt_id(receipt, key) do
    case value(receipt, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        if Limits.valid_scalar_id?(value), do: :ok, else: {:error, :invalid_id}

      _ ->
        {:error, :invalid_id}
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

  defp required_receipt_id(receipt, key, error) do
    case value(receipt, key) do
      value when is_binary(value) ->
        if Limits.valid_scalar_id?(value), do: :ok, else: {:error, :invalid_id}

      _ ->
        {:error, error}
    end
  end

  defp owner_ref(receipt) do
    owner_ref = value(receipt, :owner_ref)

    cond do
      is_map(owner_ref) and is_nil(value(owner_ref, :id)) ->
        {:error, :missing_id}

      true ->
        owner_ref_result(owner_ref)
    end
  end

  defp owner_ref_result(owner_ref) do
    case OwnerRef.normalize(owner_ref) do
      {:ok, owner_ref} -> {:ok, owner_ref}
      {:error, _reason} -> {:error, :invalid_owner_ref}
    end
  end

  defp required_string(attrs, key, error) do
    case value(attrs, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value != "" and not credential?(value), do: {:ok, value}, else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp required_scalar_id(attrs, key, error) do
    with {:ok, value} <- required_string(attrs, key, error) do
      if Limits.valid_scalar_id?(value), do: {:ok, value}, else: {:error, :invalid_id}
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

  defp required_safe_text(attrs, key, error, max) do
    case value(attrs, key) do
      value when is_binary(value) ->
        if valid_non_empty_string?(value) and byte_size(value) <= max and not credential?(value),
          do: {:ok, value},
          else: {:error, error}

      _ ->
        {:error, error}
    end
  end

  defp optional_positive_integer(map, key) do
    case value(map, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _ -> {:error, :invalid_receipt_fields}
    end
  end

  defp optional_url(map, key) do
    case value(map, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        if String.starts_with?(value, "https://") and byte_size(value) <= 2_048 and
             valid_non_empty_string?(value) and not credential?(value),
           do: :ok,
           else: {:error, :invalid_receipt_fields}

      _ ->
        {:error, :invalid_receipt_fields}
    end
  end

  defp exact_value(attrs, key, expected, error) do
    if value(attrs, key) == expected, do: :ok, else: {:error, error}
  end

  defp contract(receipt) do
    contract = value(receipt, :contract)

    cond do
      not is_map(contract) ->
        {:error, :contract_version_unsupported}

      reject_unknown_fields(contract, [:name, :version]) != :ok ->
        {:error, :contract_version_unsupported}

      is_nil(value(contract, :version)) ->
        {:error, :missing_contract_version}

      value(contract, :name) == @contract_name and value(contract, :version) == @contract_version ->
        :ok

      true ->
        {:error, :contract_version_unsupported}
    end
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

  defp required_boolean(source, key, error) do
    case value(source, key, :missing) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp reject_legacy_aliases(source) do
    cond do
      Map.has_key?(source, :commit_sha) or Map.has_key?(source, "commit_sha") ->
        {:error, :commit_sha_not_allowed}

      Map.has_key?(source, :idempotency_key) or Map.has_key?(source, "idempotency_key") ->
        {:error, :idempotency_key_not_allowed}

      true ->
        :ok
    end
  end

  defp reject_forbidden_aliases(receipt) do
    cond do
      has_any_key?(receipt, [
        :repository,
        :base_branch,
        :head_branch,
        :head_sha,
        :release_sha,
        :pr_number,
        :pr_url,
        :merged_sha,
        :merge_actor_ref,
        :post_merge_evidence_ref,
        :commit_sha,
        :idempotency_key
      ]) ->
        {:error, :forbidden_alias}

      forbidden_git_alias?(value(receipt, :git)) ->
        {:error, :forbidden_alias}

      forbidden_test_alias?(value(receipt, :tests)) ->
        {:error, :forbidden_alias}

      true ->
        :ok
    end
  end

  defp forbidden_git_alias?(git) when is_map(git),
    do: has_any_key?(git, [:status, :pushed, :commit_sha])

  defp forbidden_git_alias?(_git), do: false

  defp forbidden_test_alias?(tests) when is_list(tests) do
    Enum.any?(tests, fn test -> is_map(test) and has_any_key?(test, [:name, :commit_sha]) end)
  end

  defp forbidden_test_alias?(_tests), do: false

  defp has_any_key?(map, keys) when is_map(map) do
    Enum.any?(keys, fn key -> Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key)) end)
  end

  defp has_any_key?(_map, _keys), do: false

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

  defp valid_public_path?(path) when is_binary(path) do
    path != "" and byte_size(path) <= 512 and Path.type(path) != :absolute and
      not String.contains?(path, <<0>>) and not String.contains?(path, "\\") and
      Enum.all?(Path.split(path), &(&1 not in ["..", ".git"])) and not credential?(path)
  end

  defp valid_public_path?(_path), do: false

  defp safe_text?(value, max) when is_binary(value) do
    if byte_size(value) <= max and not credential?(value), do: :ok, else: {:error, :invalid_test}
  end

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
      ) and Ecto.UUID.cast(value) == {:ok, value}
  end

  defp valid_optional_scalar_id?(nil), do: false
  defp valid_optional_scalar_id?(value), do: Limits.valid_scalar_id?(value)

  defp required_workspace_id(receipt) do
    case value(receipt, :workspace_id) do
      value when is_binary(value) ->
        if foreign_workspace_id?(value),
          do: {:error, :foreign_lane_id},
          else: required_receipt_id(receipt, :workspace_id, :missing_id)

      _ ->
        required_receipt_id(receipt, :workspace_id, :missing_id)
    end
  end

  defp foreign_workspace_id?(value) when is_binary(value),
    do: String.starts_with?(value, "site-")

  defp foreign_workspace_id?(_value), do: false

  defp valid_non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp missing_string?(value), do: not valid_non_empty_string?(value)
  defp present?(map, key), do: not is_nil(value(map, key))

  defp credential?(value) when is_binary(value) do
    Regex.match?(
      ~r/(?:bearer\s+|password\s*=|token\s*=|api[_-]?key\s*=|gh[pousr]_|xox[baprs]-|-----begin .* private key)/i,
      value
    )
  end

  defp credential?(_value), do: false

  defp credential_map?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      credential?(to_string(key)) or credential?(item) or credential_map?(item)
    end)
  end

  defp credential_map?(value) when is_list(value), do: Enum.any?(value, &credential_map?/1)
  defp credential_map?(_value), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
