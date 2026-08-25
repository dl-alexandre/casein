defmodule Casein.Agents.JidoSkills.Selector do
  @moduledoc false

  alias Casein.Agents.{Activity, JidoPod}
  alias Casein.Agents.JidoSkills.Registry

  @type selection :: %{
          runtime: :jido | :opencode,
          fallback?: boolean(),
          reason: atom(),
          skill: String.t() | nil,
          supported?: boolean(),
          missing: [String.t()],
          shadow?: boolean(),
          canary?: boolean(),
          model: String.t(),
          provider: String.t(),
          headless: boolean(),
          pane_required?: false
        }

  @type fallback :: %{
          runtime: :opencode,
          fallback?: true,
          reason: atom(),
          prior_attempt_id: String.t() | nil,
          workspace_id: String.t() | nil,
          completed_mutation_tokens: [String.t()],
          resume_from: non_neg_integer(),
          applied?: false,
          headless: boolean(),
          pane_required?: false
        }

  @fallback_reasons ~w(provider_unavailable tool_failure runtime_failure)a

  @spec select(String.t(), keyword() | map()) :: {:ok, selection()} | {:error, map()}
  def select(workspace_id, opts \\ [])

  def select(workspace_id, opts) when is_binary(workspace_id) and is_list(opts) do
    select(workspace_id, Map.new(opts))
  end

  def select(workspace_id, opts) when is_binary(workspace_id) and is_map(opts) do
    requested = requested_runtime(opts)
    enabled? = JidoPod.enabled?(workspace_id, opts)
    mode = mode(opts)

    with {:ok, skill, support} <- resolve_skill(opts) do
      cond do
        requested == :opencode ->
          {:ok, selection(:opencode, :explicit_opencode, skill, support, mode, enabled?)}

        requested == :jido and not enabled? ->
          {:error, fail(:jido_disabled, skill, support, "Jido is not enabled for this workspace")}

        match?(%{supported?: false, reason: reason} when reason != nil, support) and
          requested in [:jido, nil] and enabled? ->
          {:error, unsupported_error(skill, support)}

        requested == :jido ->
          {:ok, selection(:jido, :explicit_jido, skill, support, mode, true)}

        enabled? ->
          {:ok, selection(:jido, :jido_default, skill, support, mode, true)}

        true ->
          {:ok, selection(:opencode, :legacy_opencode, skill, support, mode, false)}
      end
    end
  end

  def select(_workspace_id, _opts) do
    {:error, %{error: :invalid, result: :invalid, message: "workspace_id required"}}
  end

  @spec fallback(map(), atom()) :: fallback()
  def fallback(prior, reason) when is_map(prior) and reason in @fallback_reasons do
    tokens = completed_tokens(prior)
    resume_from = Map.get(prior, :next_index) || Map.get(prior, "next_index") || length(tokens)
    workspace_id = Map.get(prior, :workspace_id) || Map.get(prior, "workspace_id")
    attempt_id = Map.get(prior, :attempt_id) || Map.get(prior, "attempt_id")

    receipt = %{
      runtime: :opencode,
      fallback?: true,
      reason: reason,
      prior_attempt_id: attempt_id,
      workspace_id: workspace_id,
      completed_mutation_tokens: tokens,
      resume_from: resume_from,
      applied?: false,
      headless: true,
      pane_required?: false
    }

    record_fallback(receipt)
    receipt
  end

  def fallback(prior, reason) when is_map(prior) do
    fallback(prior, normalize_reason(reason))
  end

  @spec remaining_actions(fallback() | map(), [map()]) :: [map()]
  def remaining_actions(%{completed_mutation_tokens: tokens}, actions) when is_list(actions) do
    taken = MapSet.new(tokens)

    Enum.reject(actions, fn action ->
      token = Map.get(action, :mutation_token) || Map.get(action, "mutation_token")
      is_binary(token) and token != "" and MapSet.member?(taken, token)
    end)
  end

  def remaining_actions(_receipt, actions) when is_list(actions), do: actions

  defp resolve_skill(opts) do
    case skill_name(opts) do
      nil ->
        {:ok, nil, %{supported?: true, missing: [], reason: nil, skill: nil}}

      name ->
        roots = Map.get(opts, :roots) || Map.get(opts, "roots") || Registry.default_roots()

        case Registry.get(name, roots) do
          {:ok, skill} -> {:ok, skill, Registry.support(skill)}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp unsupported_error(skill, support) do
    reason = support.reason || :not_yet_supported
    name = if is_map(skill), do: skill.name, else: support.skill

    %{
      error: reason,
      result: :not_yet_supported,
      skill: name,
      missing: support.missing,
      forbidden: Map.get(support, :forbidden, []),
      message: "skill #{name} is not supported on headless Jido",
      retryable: false
    }
  end

  defp fail(error, skill, support, message) do
    %{
      error: error,
      result: :denied,
      skill: skill && skill.name,
      missing: Map.get(support, :missing, []),
      message: message,
      retryable: false
    }
  end

  defp selection(runtime, reason, skill, support, mode, enabled?) do
    %{
      runtime: runtime,
      fallback?: false,
      reason: reason,
      skill: skill && skill.name,
      supported?: support.supported?,
      missing: support.missing,
      shadow?: mode == :shadow,
      canary?: mode == :canary,
      model: Registry.default_model(),
      provider: Registry.default_provider(),
      headless: runtime == :jido or enabled?,
      pane_required?: false
    }
  end

  defp requested_runtime(opts) do
    case Map.get(opts, :runtime) || Map.get(opts, "runtime") do
      :opencode -> :opencode
      "opencode" -> :opencode
      :jido -> :jido
      "jido" -> :jido
      :fallback -> :opencode
      "fallback" -> :opencode
      _ -> nil
    end
  end

  defp mode(opts) do
    case Map.get(opts, :mode) || Map.get(opts, "mode") do
      :shadow -> :shadow
      "shadow" -> :shadow
      :canary -> :canary
      "canary" -> :canary
      _ -> :primary
    end
  end

  defp skill_name(opts) do
    case Map.get(opts, :skill) || Map.get(opts, "skill") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp completed_tokens(prior) do
    completed = Map.get(prior, :completed) || Map.get(prior, "completed") || []

    completed
    |> Enum.map(fn item ->
      Map.get(item, :mutation_token) || Map.get(item, "mutation_token")
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp normalize_reason(:provider_failure), do: :provider_unavailable
  defp normalize_reason("provider_unavailable"), do: :provider_unavailable
  defp normalize_reason("tool_failure"), do: :tool_failure
  defp normalize_reason("runtime_failure"), do: :runtime_failure
  defp normalize_reason(_), do: :runtime_failure

  defp record_fallback(receipt) do
    workspace_id = receipt.workspace_id

    if is_binary(workspace_id) do
      Activity.record(%{
        workspace_id: workspace_id,
        source: :jido_skills,
        tool: "jido_fallback",
        summary: "fallback to opencode (#{receipt.reason})",
        metadata: %{
          reason: receipt.reason,
          prior_attempt_id: receipt.prior_attempt_id,
          completed_mutation_tokens: receipt.completed_mutation_tokens,
          resume_from: receipt.resume_from,
          runtime: :opencode,
          fallback?: true,
          headless: true
        },
        status: :ok
      })
    end
  end
end
