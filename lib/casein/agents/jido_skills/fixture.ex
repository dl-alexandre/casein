defmodule Casein.Agents.JidoSkills.Fixture do
  @moduledoc false

  alias Casein.Agents.{Activity, CodeTools, JidoActions}
  alias Casein.Agents.JidoSkills.{Attempt, Registry}

  @skill "representative-edit"

  @spec run_fixture(atom(), map()) :: {:ok, map()} | {:error, map()}
  def run_fixture(backend, opts) when backend in [:jido, :opencode] and is_map(opts) do
    workspace_id = Map.fetch!(opts, :workspace_id)
    worktree = Map.fetch!(opts, :worktree_path)
    task_id = Map.get(opts, :task_id, "task-representative-edit")

    attempt_id =
      Map.get(opts, :attempt_id, "attempt-#{backend}-#{System.unique_integer([:positive])}")

    roots = Map.get(opts, :roots) || Registry.default_roots()

    with {:ok, skill} <- Registry.get(@skill, roots) do
      ctx = %{
        workspace_id: workspace_id,
        task_id: task_id,
        attempt_id: attempt_id,
        worktree_path: worktree,
        actor: Map.get(opts, :actor, "ws:#{workspace_id}"),
        correlation_id: attempt_id
      }

      binding =
        Attempt.bind_attempt(%{
          workspace_id: workspace_id,
          task_id: task_id,
          attempt_id: attempt_id,
          worktree_path: worktree,
          backend: backend,
          skill: skill
        })

      steps = steps(opts)
      results = Enum.map(steps, &invoke(backend, &1, ctx))

      {:ok,
       %{
         backend: backend,
         skill: skill.name,
         skill_version: skill.version,
         catalog_digest: binding.catalog_digest,
         outcome: outcome(results),
         changed_paths: changed_paths(results),
         verification: verification(results),
         audit_identity: %{
           workspace_id: workspace_id,
           task_id: task_id,
           attempt_id: attempt_id,
           backend: backend
         },
         binding: binding,
         results: results,
         headless: true,
         pane_id: nil
       }}
    end
  end

  def run_fixture(_backend, _opts) do
    {:error, %{error: :invalid, result: :invalid, message: "backend must be :jido or :opencode"}}
  end

  defp steps(opts) do
    path = Map.get(opts, :path, "lib/hello.ex")
    query = Map.get(opts, :query, "needle")
    patch = Map.get(opts, :patch)
    command_id = Map.get(opts, :command_id, "format")

    [
      %{name: "code_read", args: %{path: path}},
      %{name: "code_search", args: %{query: query}},
      %{
        name: "code_apply_patch",
        args: %{patch: patch, idempotency_key: Map.get(opts, :idempotency_key, "fix-1")}
      },
      %{
        name: "code_exec",
        args: %{command_id: command_id, timeout_ms: Map.get(opts, :timeout_ms, 1)}
      },
      %{name: "report_progress", args: %{summary: "patched #{path}"}},
      %{name: "handoff_evidence", args: %{paths: [path], verification_ref: command_id}}
    ]
    |> Enum.reject(fn step ->
      step.name == "code_apply_patch" and not is_binary(step.args.patch)
    end)
  end

  defp invoke(:jido, step, ctx) do
    wrap(step.name, JidoActions.invoke(step.name, step.args, ctx))
  end

  defp invoke(:opencode, step, ctx) do
    result =
      cond do
        step.name in ~w(code_read code_search code_apply_patch code_exec) ->
          CodeTools.invoke(step.name, Map.merge(step.args, identity_args(ctx)), %{
            actor: ctx.actor
          })

        true ->
          Activity.record(%{
            workspace_id: ctx.workspace_id,
            source: :jido_skills,
            tool: step.name,
            summary: "opencode #{step.name}",
            metadata: %{
              backend: :opencode,
              task_id: ctx.task_id,
              attempt_id: ctx.attempt_id,
              correlation_id: ctx.correlation_id
            },
            status: :ok
          })

          {:ok, Map.merge(%{recorded: true, result: :ok}, step.args)}
      end

    wrap(step.name, result)
  end

  defp identity_args(ctx) do
    %{
      workspace_id: ctx.workspace_id,
      worktree_path: ctx.worktree_path,
      task_id: ctx.task_id,
      attempt_id: ctx.attempt_id
    }
  end

  defp wrap(name, {:ok, payload}) when is_map(payload) do
    %{name: name, ok?: true, payload: Map.put_new(payload, :result, :ok)}
  end

  defp wrap(name, {:error, payload}) when is_map(payload) do
    %{name: name, ok?: false, payload: payload}
  end

  defp wrap(name, {:error, reason}) do
    %{name: name, ok?: false, payload: %{error: reason, result: :denied}}
  end

  defp outcome(results) do
    if Enum.all?(results, &acceptable?/1), do: :ok, else: :failed
  end

  defp acceptable?(%{name: "code_exec", payload: payload}) do
    payload[:result] in [:ok, :timeout, nil] or payload[:timed_out] == true
  end

  defp acceptable?(%{ok?: ok?}), do: ok?

  defp changed_paths(results) do
    results
    |> Enum.flat_map(fn
      %{name: "code_apply_patch", payload: payload} ->
        List.wrap(payload[:paths] || payload["paths"])

      %{name: "handoff_evidence", payload: payload} ->
        List.wrap(payload[:paths] || payload["paths"])

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp verification(results) do
    case Enum.find(results, &(&1.name == "code_exec")) do
      %{payload: payload} -> payload[:command_id] || payload["command_id"] || payload[:result]
      _ -> nil
    end
  end
end
