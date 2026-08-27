defmodule Casein.Agents.JidoWorkcell.Git do
  @moduledoc """
  Audited Git boundary for headless Jido workers.

  This module owns scope validation and handoff idempotency. It intentionally
  has no pull-request, review, approval, merge, deploy, shell, or tmux API.
  Dash/Verda consumes the resulting receipt for live repository operations.
  """

  alias Casein.Agents.JidoWorkcell.Git.{Ledger, LocalAdapter, Scope}
  alias Casein.Agents.JidoWorkcell.Limits
  alias Casein.Agents.JidoWorkcell.Receipt

  @spec bind(map()) :: {:ok, Scope.t()} | {:error, term()}
  def bind(attrs) when is_map(attrs) do
    with {:ok, scope} <- Scope.new(attrs),
         {:ok, scope} <- adapter().bind(scope) do
      {:ok, scope}
    end
  end

  def bind(_attrs), do: {:error, :invalid_scope}

  @spec status(Scope.t()) :: {:ok, map()} | {:error, term()}
  def status(%Scope{} = scope), do: adapter().status(scope)
  def status(_scope), do: {:error, :invalid_scope}

  @spec diff(Scope.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def diff(%Scope{} = scope, paths), do: adapter().diff(scope, paths)
  def diff(_scope, _paths), do: {:error, :invalid_scope}

  @spec handoff(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def handoff(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, paths} <- Scope.validate_paths(scope, value(attrs, :paths, scope.allowed_paths)),
         {:ok, message} <- Scope.validate_commit_message(value(attrs, :message)),
         {:ok, handoff_id} <- required_handoff_id(attrs),
         {:ok, _receipt_id} <- required_receipt_id(attrs),
         :ok <- Receipt.validate_handoff_scope(scope),
         :ok <- push_allowed(scope),
         {:ok, expected_head_sha} <- expected_head_sha(attrs) do
      fingerprint =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({Scope.public(scope), paths, message, receipt_attrs(attrs)})
        )

      Ledger.run(handoff_id, fingerprint, expected_head_sha, fn ->
        do_handoff(scope, attrs, paths, message)
      end)
    end
  end

  def handoff(_scope, _attrs), do: {:error, :invalid_scope}

  @spec adapter() :: module()
  def adapter do
    Casein.ProcessEnv.get(:casein, :jido_workcell_git_adapter, LocalAdapter)
  end

  defp do_handoff(scope, attrs, paths, message) do
    with {:ok, _staged} <- adapter().stage(scope, paths),
         {:ok, commit} <- adapter().commit(scope, %{message: message, paths: paths}),
         {:ok, sha} <- current_sha(commit, scope),
         :ok <- expected_head_sha_matches(attrs, sha),
         {:ok, receipt} <-
           Receipt.build(
             scope,
             Map.merge(commit, %{head_sha: sha, pushed?: true, branch: scope.assigned_branch}),
             attrs
           ),
         {:ok, pushed} <- adapter().push(scope),
         :ok <- pushed?(pushed) do
      {:ok, receipt}
    end
  end

  defp pushed?(%{} = result) do
    case value(result, :pushed?, :missing) do
      true -> :ok
      _ -> {:error, :push_not_confirmed}
    end
  end

  defp pushed?(_result), do: {:error, :push_not_confirmed}

  defp current_sha(%{head_sha: sha}, _scope) when is_binary(sha), do: {:ok, sha}
  defp current_sha(_commit, scope), do: adapter().head_sha(scope)

  defp required_handoff_id(attrs) do
    case value(attrs, :handoff_id) do
      id when is_binary(id) ->
        if Limits.valid_scalar_id?(id), do: {:ok, id}, else: {:error, :invalid_handoff_id}

      _ ->
        {:error, :handoff_id_required}
    end
  end

  defp required_receipt_id(attrs) do
    case value(attrs, :receipt_id) do
      id when is_binary(id) ->
        if Limits.valid_scalar_id?(id), do: {:ok, id}, else: {:error, :invalid_receipt_id}

      _ ->
        {:error, :receipt_id_required}
    end
  end

  defp push_allowed(%Scope{push_allowed?: true}), do: :ok
  defp push_allowed(%Scope{}), do: {:error, :push_not_authorized}

  defp expected_head_sha(attrs) do
    case value(attrs, :head_sha) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if Receipt.valid_sha?(value), do: {:ok, value}, else: {:error, :invalid_head_sha}

      _ ->
        {:error, :invalid_head_sha}
    end
  end

  defp expected_head_sha_matches(attrs, actual_sha) do
    case value(attrs, :head_sha) do
      nil -> :ok
      expected when expected == actual_sha -> :ok
      _ -> {:error, :identity_mismatch}
    end
  end

  defp receipt_attrs(attrs) do
    Enum.reduce(
      [
        :receipt_id,
        :handoff_id,
        :tests,
        :artifacts,
        :blocker,
        :head_sha,
        :evidence_ref,
        :decision_id,
        :session_id,
        :workcell_id,
        :workcell_assigned?,
        :scheduler_assigned?,
        :task_id,
        :lease_id,
        :correlation_id,
        :source,
        :origin,
        :lane
      ],
      %{},
      fn key, acc -> Map.put(acc, key, value(attrs, key)) end
    )
  end

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
