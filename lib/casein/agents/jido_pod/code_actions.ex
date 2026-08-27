defmodule Casein.Agents.JidoPod.CodeActions do
  @moduledoc """
  Thin worker boundary onto typed Jido actions.

  Workers must not open a shell, walk the filesystem, or drive tmux. They call
  this module, which forwards code actions to `Casein.Agents.CodeTools` and
  lifecycle/reporting actions to `Casein.Agents.JidoActions`. Git/task
  follow-up tools are accepted only through the audited Workcell Git scope;
  task control remains outside this worker boundary.
  """

  @code_actions ~w(code_read code_search code_apply_patch code_exec)
  @git_actions ~w(git_status git_diff git_handoff)
  @handoff_actions ~w(request_clarification request_human_input report_progress report_result handoff_evidence)
  @allowed @code_actions ++ @git_actions ++ @handoff_actions

  @spec allowed?(String.t()) :: boolean()
  def allowed?(name) when is_binary(name), do: name in @allowed
  def allowed?(_), do: false

  @spec allowed() :: [String.t()]
  def allowed, do: @allowed

  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(name, args, context \\ %{})

  def invoke(name, args, context) when is_binary(name) and is_map(args) and is_map(context) do
    cond do
      name in @code_actions ->
        runner().(name, stamp(args, context), context)

      name in @handoff_actions or name in @git_actions ->
        # Handoff and Git actions have strict schemas. Their workspace,
        # attempt, and worktree identity belongs in the trusted context and
        # must not be copied into model-authored action arguments.
        jido_actions_invoke(name, args, context)

      true ->
        {:error, %{error: :unknown_tool, message: "unsupported Jido action #{name}"}}
    end
  end

  def invoke(_name, _args, _context), do: {:error, :invalid_argument}

  defp stamp(args, context) do
    Enum.reduce([:workspace_id, :worktree_path, :task_id, :attempt_id], args, fn key, acc ->
      cond do
        Map.has_key?(acc, key) or Map.has_key?(acc, Atom.to_string(key)) ->
          acc

        match?(%{^key => value} when is_binary(value), context) ->
          Map.put(acc, key, Map.fetch!(context, key))

        true ->
          acc
      end
    end)
  end

  defp runner do
    Application.get_env(:casein, :jido_code_actions, &default_invoke/3)
  end

  defp default_invoke(name, args, context) do
    code_tools_invoke(name, args, context)
  end

  defp jido_actions_invoke(name, args, context) do
    module = Module.concat(Casein.Agents, JidoActions)

    if Code.ensure_loaded?(module) and function_exported?(module, :invoke, 3) do
      module.invoke(name, args, context)
    else
      {:error, :jido_actions_unavailable}
    end
  end

  defp code_tools_invoke(name, args, context) do
    module = Module.concat(Casein.Agents, CodeTools)

    if Code.ensure_loaded?(module) and function_exported?(module, :invoke, 3) do
      module.invoke(name, args, context)
    else
      {:error, :code_tools_unavailable}
    end
  end
end
