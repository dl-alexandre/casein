defmodule Casein.Agents.JidoPod.CodeActions do
  @moduledoc """
  Thin worker boundary onto typed Casein Code actions.

  Workers must not open a shell, walk the filesystem, or drive tmux. They call
  this module, which forwards to `Casein.Agents.CodeTools` (#1013) when that
  contract is loaded. Follow-up tools (`git_status`, `git_diff`, `task_wait`,
  `task_cancel`) are rejected here on purpose.
  """

  @allowed ~w(code_read code_search code_apply_patch code_exec)

  @spec allowed?(String.t()) :: boolean()
  def allowed?(name) when is_binary(name), do: name in @allowed
  def allowed?(_), do: false

  @spec allowed() :: [String.t()]
  def allowed, do: @allowed

  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(name, args, context \\ %{})

  def invoke(name, args, context) when is_binary(name) and is_map(args) and is_map(context) do
    if allowed?(name) do
      runner().(name, stamp(args, context), context)
    else
      {:error, %{error: :unknown_tool, message: "unsupported code action #{name}"}}
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

  defp code_tools_invoke(name, args, context) do
    module = Module.concat(Casein.Agents, CodeTools)

    if Code.ensure_loaded?(module) and function_exported?(module, :invoke, 3) do
      module.invoke(name, args, context)
    else
      {:error, :code_tools_unavailable}
    end
  end
end
