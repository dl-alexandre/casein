defmodule Casein.Credo.Check.NoRemoteResolveInSingleton do
  @moduledoc false

  # Flags opts-less `viewer_ids/1` inside modules that `use GenServer`.
  #
  # `Casein.Workspaces.Aliases.viewer_ids/2` defaults `resolve_remote?` to true,
  # which enables a cold-State HTTP fallback. Called inline from a singleton
  # GenServer's broadcast fan-out, one raise cascades (#314). Always pass
  # `resolve_remote?: false` from GenServer modules.

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Do not call `viewer_ids/1` (one argument) inside a module that `use GenServer`.

      `Casein.Workspaces.Aliases.viewer_ids/2` defaults `resolve_remote?` to `true`.
      That enables a cold-`State` HTTP fallback which can block or crash a long-lived
      singleton GenServer (see PR #314).

      Pass `resolve_remote?: false` from GenServer code paths:

          workspaces().viewer_ids(workspace_id, resolve_remote?: false)

      Fan-out is best-effort; a cold cache degrades to the canonical id and
      self-heals on the next poll.
      """
    ]

  alias Credo.Check.Context
  alias Credo.SourceFile

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params \\ []) do
    ctx = Context.build(source_file, params, __MODULE__)

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        ast
        |> collect_genserver_modules()
        |> Enum.reduce(ctx, fn module_ast, acc ->
          issues = bad_call_issues(module_ast, acc)
          Context.put_issue(acc, issues)
        end)
        |> Map.fetch!(:issues)

      {:error, _} ->
        []
    end
  end

  defp collect_genserver_modules(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, _body]} = mod_ast, acc ->
          if uses_genserver?(mod_ast) do
            {mod_ast, [mod_ast | acc]}
          else
            {mod_ast, acc}
          end

        other, acc ->
          {other, acc}
      end)

    Enum.reverse(modules)
  end

  defp uses_genserver?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, acc or genserver_alias?(parts)}

        {:use, _, [{:GenServer, _, _} | _]} = node, _acc ->
          {node, true}

        other, acc ->
          {other, acc}
      end)

    found?
  end

  defp genserver_alias?([:GenServer]), do: true
  defp genserver_alias?(parts) when is_list(parts), do: List.last(parts) == :GenServer
  defp genserver_alias?(_), do: false

  defp bad_call_issues(module_ast, ctx) do
    {_ast, issues} = Macro.prewalk(module_ast, [], &collect_issue(&1, &2, ctx))
    Enum.reverse(issues)
  end

  # Skip function heads so `def viewer_ids/1` is not flagged as a call.
  # Walk the body ourselves, then return atoms so the outer Macro.prewalk
  # does not re-descend (which would double-report the same call).
  defp collect_issue({kind, meta, [_head, body]}, acc, ctx)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    body_acc =
      case body do
        nil ->
          acc

        other ->
          {_walked, next_acc} = Macro.prewalk(other, acc, &collect_issue(&1, &2, ctx))
          next_acc
      end

    {{kind, meta, [:__credo_skipped_head__, :__credo_skipped_body__]}, body_acc}
  end

  defp collect_issue(ast, acc, ctx) do
    case match_viewer_ids_call(ast) do
      {:bad, meta} ->
        {ast, [issue_for(ctx, meta) | acc]}

      :ok ->
        {ast, acc}
    end
  end

  # Local call: viewer_ids(x)
  defp match_viewer_ids_call({:viewer_ids, meta, args}) when is_list(args) do
    if length(args) == 1, do: {:bad, meta}, else: :ok
  end

  # Remote / chained call: Mod.viewer_ids(x), foo().viewer_ids(x), ...
  defp match_viewer_ids_call({{:., meta, [_left, :viewer_ids]}, _call_meta, args})
       when is_list(args) do
    if length(args) == 1, do: {:bad, meta}, else: :ok
  end

  # Piped zero-arg form: x |> viewer_ids()  /  x |> Mod.viewer_ids()
  defp match_viewer_ids_call({:|>, _pipe_meta, [_left, right]}) do
    case right do
      {:viewer_ids, meta, args} when is_list(args) and args == [] ->
        {:bad, meta}

      {:viewer_ids, meta, nil} ->
        {:bad, meta}

      {{:., meta, [_mod, :viewer_ids]}, _call_meta, args} when is_list(args) and args == [] ->
        {:bad, meta}

      {{:., meta, [_mod, :viewer_ids]}, _call_meta, nil} ->
        {:bad, meta}

      _ ->
        :ok
    end
  end

  defp match_viewer_ids_call(_), do: :ok

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "Do not call `viewer_ids/1` inside a GenServer module; pass `resolve_remote?: false` " <>
          "(cold-State HTTP fallback can crash the singleton — see #314).",
      trigger: "viewer_ids",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
