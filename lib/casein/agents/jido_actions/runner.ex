defmodule Casein.Agents.JidoActions.Runner do
  @moduledoc false

  alias Casein.Agents.{AgentEvents, CodeTools, ToolAction}
  alias Casein.Agents.JidoActions.{Context, Result}
  alias Casein.Agents.JidoWorkcell.Git

  @spec forward_code(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def forward_code(name, params, ctx) when is_binary(name) and is_map(params) and is_map(ctx) do
    args =
      params
      |> Map.merge(%{
        workspace_id: ctx.workspace_id,
        worktree_path: Map.get(ctx, :worktree_path),
        task_id: Map.get(ctx, :task_id),
        attempt_id: Map.get(ctx, :attempt_id)
      })
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    case code_invoke().(name, args, %{actor: Map.get(ctx, :principal)}) do
      {:ok, %{status: "failed"} = payload} ->
        {:error, Map.put(payload, :error, :verification_failed)}

      {:ok, %{status: "error"} = payload} ->
        {:error, Map.put(payload, :error, :execution_failed)}

      other ->
        other
    end
  end

  @spec git_status(map()) :: {:ok, map()} | {:error, term()}
  def git_status(ctx) when is_map(ctx) do
    with {:ok, scope} <- git_scope(ctx) do
      Git.status(scope)
    end
  end

  @spec git_diff(map(), map()) :: {:ok, map()} | {:error, term()}
  def git_diff(params, ctx) when is_map(params) and is_map(ctx) do
    with {:ok, scope} <- git_scope(ctx),
         {:ok, paths} <- fetch_paths(params) do
      Git.diff(scope, paths)
    end
  end

  @spec git_handoff(map(), map()) :: {:ok, map()} | {:error, term()}
  def git_handoff(params, ctx) when is_map(params) and is_map(ctx) do
    with {:ok, scope} <- git_scope(ctx) do
      Git.handoff(scope, Map.merge(params, trusted_handoff_context(ctx)))
    end
  end

  @spec unsupported(String.t(), map()) :: {:error, map()}
  def unsupported(name, ctx) do
    {:error,
     %{
       error: :not_yet_supported,
       result: :not_yet_supported,
       action: name,
       message: "#{name} is not on the Code MCP contract yet",
       retryable: false
     }
     |> maybe_merge(ctx)}
  end

  @spec block_on_human(String.t(), map(), map()) :: {:error, map()}
  def block_on_human(name, attrs, ctx) when is_map(attrs) and is_map(ctx) do
    request_id = Map.fetch!(attrs, :request_id)
    kind = Map.get(attrs, :kind, "clarification")
    prompt = Map.get(attrs, :prompt) || Map.get(attrs, :question)
    choices = Map.get(attrs, :choices) || []

    _ =
      AgentEvents.append(%{
        workspace_id: ctx.workspace_id,
        stream_id:
          "jido:" <> (Map.get(ctx, :attempt_id) || Map.get(ctx, :correlation_id) || "none"),
        producer: "jido",
        ingress: "jido_actions",
        source_event_id: "request:#{request_id}",
        event_type: "agent.clarification_requested",
        privacy_class: "operator_content",
        agent_session_id: Map.get(ctx, :attempt_id),
        actor_id: Map.get(ctx, :principal),
        status: "open",
        summary: "Headless worker requested human input",
        payload: %{
          "schema_version" => 1,
          "request_id" => request_id,
          "request_kind" => kind,
          "question" => prompt,
          "choices" => choices,
          "headless" => true,
          "action" => name
        }
      })

    {:error,
     %{
       error: :awaiting_human,
       result: :blocked_on_human,
       awaiting_human: true,
       status: :awaiting_human,
       request_id: request_id,
       kind: kind,
       action: name,
       retryable: false
     }
     |> maybe_merge(ctx)}
  end

  @spec report(String.t(), map(), map()) :: {:ok, map()}
  def report(name, attrs, ctx) when is_map(attrs) and is_map(ctx) do
    {:ok,
     %{
       recorded: true,
       action: name,
       idempotent: true
     }
     |> Map.merge(attrs)
     |> maybe_merge(ctx)}
  end

  @spec invoke_action(module(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke_action(action, args, ctx) do
    keys = Keyword.keys(action.schema())
    ToolAction.invoke(action, Context.capability_args(args, keys), ctx)
  end

  defp code_invoke do
    Application.get_env(:casein, :jido_actions_code_invoke, &CodeTools.invoke/3)
  end

  defp maybe_merge(payload, ctx) do
    Map.merge(
      %{
        workspace_id: Map.get(ctx, :workspace_id),
        task_id: Map.get(ctx, :task_id),
        attempt_id: Map.get(ctx, :attempt_id),
        worktree_path: Map.get(ctx, :worktree_path),
        correlation_id: Map.get(ctx, :correlation_id)
      },
      payload
    )
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defdelegate normalize(name, result, ctx), to: Result

  defp git_scope(%{git_scope: %Casein.Agents.JidoWorkcell.Git.Scope{} = scope}), do: {:ok, scope}
  defp git_scope(_ctx), do: {:error, :git_scope_required}

  defp fetch_paths(params) do
    case Map.get(params, :paths) || Map.get(params, "paths") do
      paths when is_list(paths) -> {:ok, paths}
      _ -> {:error, :paths_required}
    end
  end

  defp trusted_handoff_context(ctx) do
    identity =
      Map.take(ctx, [
        :session_id,
        :workcell_id,
        :workcell_assigned?,
        :source,
        :receipt_id,
        :request_id,
        :authorization,
        :evidence_ref,
        :decision_id,
        :lane,
        :origin,
        :release_sha,
        :owner_ref,
        :runtime_id,
        :worker_id
      ])

    # A Workcell lease is an internal admission guard. Only a real Mira/Oban
    # task lease may cross the receipt boundary; otherwise Gate 0 correctly
    # rejects the producer as a foreign-lane receipt.
    lane_ids =
      if Map.get(ctx, :origin) in [:mira, :oban, "mira", "oban"] do
        Map.take(ctx, [:task_id, :lease_id, :correlation_id])
      else
        %{}
      end

    identity
    |> Map.merge(lane_ids)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end
end
