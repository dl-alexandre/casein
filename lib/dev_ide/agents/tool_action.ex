defmodule DevIDE.Agents.ToolAction do
  @moduledoc """
  Contract and runner for MCP tools backed by `Jido.Action` modules.

  A tool action pairs Jido's runtime param validation (`schema:`) with a
  hand-written MCP JSON Schema (`parameters/0`) that defines the wire shape.
  The two stay separate on purpose: JSON Schema features like `oneOf`/`enum`
  are not expressible in NimbleOptions, and the wire bytes are locked by the
  MCP contract tests.

  The runner normalizes string-keyed MCP arguments onto the action's schema
  keys before validation. This is load-bearing: `validate_params/1` only
  validates keys it recognizes (the schema's atom keys) and passes unknown
  keys through untouched, so unnormalized string-keyed args would bypass
  validation entirely. The schema doubles as the argument whitelist — keys
  the schema doesn't declare are dropped, and no atom is ever created from
  input (`DevIDE.PayloadAttrs` handles the string/atom fallback).

  Actions are executed via `validate_params/1` + `run/2` directly rather
  than `Jido.Exec.run/3`: Exec adds task-wrapped timeouts and retries, and
  retrying mutating tools that commit to Git would risk duplicate commits.
  """

  alias DevIDE.PayloadAttrs
  alias DevIDE.Signals.Context
  alias McpCtl.Tool

  @default_timeout_ms 30_000

  @doc "MCP JSON Schema for tools/list, built with `McpCtl.Tool.object/2`."
  @callback parameters() :: map()

  @doc "MCP tool metadata (mutation flag, danger level, capabilities, hints)."
  @callback mcp_metadata() :: Tool.metadata()

  @doc "Accepted argument names per schema key; first present value wins."
  @callback param_aliases() :: %{optional(atom()) => [String.t()]}

  @optional_callbacks param_aliases: 0

  @doc "Build the MCP tool definition from the action's introspection."
  @spec definition(module()) :: Tool.t()
  def definition(action) do
    Tool.define(action.name(), action.description(), action.parameters(), action.mcp_metadata())
  end

  @doc """
  Normalize, validate, and run an action against raw MCP arguments.

  Required string params are trimmed (whitespace-only counts as missing,
  matching the previous hand-rolled `required_string/2` semantics); optional
  params pass through untouched.
  """
  @spec invoke(module(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(action, args, context \\ %{}) when is_map(args) do
    schema = action.schema()
    params = normalize(args, schema, aliases(action))

    with {:ok, params} <- check_required(params, schema),
         {:ok, validated} <- validate(action, params) do
      run_with_timeout(action, validated, context)
    end
  end

  defp run_with_timeout(action, validated, context) do
    timeout_ms = timeout_ms_for(action)
    started_at = System.monotonic_time(:millisecond)
    task = Context.async(fn -> action.run(validated, context) end)

    result =
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, run_result} ->
          emit_tool_stop(action, started_at, false)
          run_result

        {:exit, reason} ->
          emit_tool_stop(action, started_at, false)
          {:error, %{error: :tool_crashed, message: Exception.format_exit(reason)}}

        nil ->
          emit_tool_stop(action, started_at, true)

          {:error,
           %{
             error: :timeout,
             message: "tool #{action.name()} timed out after #{timeout_ms}ms"
           }}
      end

    result
  end

  defp timeout_ms_for(action) do
    action
    |> mcp_metadata()
    |> Map.get(:timeout_ms, @default_timeout_ms)
  end

  defp mcp_metadata(action) do
    if function_exported?(action, :mcp_metadata, 0), do: action.mcp_metadata(), else: %{}
  end

  defp emit_tool_stop(action, started_at, timed_out?) do
    duration = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:dev_ide, :agents, :tool, :stop],
      %{duration: duration},
      %{tool: action.name(), timed_out: timed_out?}
    )
  end

  defp aliases(action) do
    if function_exported?(action, :param_aliases, 0), do: action.param_aliases(), else: %{}
  end

  defp normalize(args, schema, aliases) do
    Enum.reduce(schema, %{}, fn {key, _opts}, acc ->
      case fetch_value(args, Map.get(aliases, key, [Atom.to_string(key)])) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_value(_args, []), do: :error

  defp fetch_value(args, [name | rest]) do
    case PayloadAttrs.fetch(args, name) do
      # Explicit JSON nulls count as absent (clients send them for optional
      # fields), so the alias chain keeps looking — {"artifact_id": null,
      # "id": "abc"} must still resolve "abc". An explicit false survives:
      # boolean arguments like gate_report's `passed` are load-bearing
      # either way.
      {:ok, nil} -> fetch_value(args, rest)
      {:ok, value} -> {:ok, value}
      :error -> fetch_value(args, rest)
    end
  end

  defp check_required(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {key, opts}, {:ok, acc} ->
      if opts[:required] do
        check_required_value(acc, key)
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp check_required_value(params, key) do
    case Map.get(params, key) do
      nil ->
        {:halt, {:error, {:missing_argument, Atom.to_string(key)}}}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:halt, {:error, {:missing_argument, Atom.to_string(key)}}}
          trimmed -> {:cont, {:ok, Map.put(params, key, trimmed)}}
        end

      # Non-string values fall through to schema validation (invalid_argument).
      _other ->
        {:cont, {:ok, params}}
    end
  end

  defp validate(action, params) do
    case action.validate_params(params) do
      {:ok, validated} -> {:ok, validated}
      {:error, err} -> {:error, %{error: :invalid_argument, message: error_message(err)}}
    end
  end

  defp error_message(%{__exception__: true} = err), do: Exception.message(err)
  defp error_message(err) when is_binary(err), do: err
  defp error_message(err), do: inspect(err)
end
