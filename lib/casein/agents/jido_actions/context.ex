defmodule Casein.Agents.JidoActions.Context do
  @moduledoc """
  Trusted invocation identity for typed Jido worker actions.

  Workspace, task, attempt, worktree, principal, capability profile, and
  correlation come from the caller-supplied context (the pod/attempt), never
  from model-authored tool arguments. Conflicting identity in args is a deny.
  """

  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoPod.Attempt
  alias Casein.PayloadAttrs

  @type t :: %{
          required(:workspace_id) => String.t(),
          optional(:task_id) => String.t(),
          optional(:attempt_id) => String.t(),
          optional(:worktree_path) => String.t(),
          optional(:principal) => String.t(),
          optional(:capability) => atom() | String.t(),
          optional(:correlation_id) => String.t()
        }

  @identity_keys [:workspace_id, :task_id, :attempt_id, :worktree_path]

  @spec resolve(map(), map()) :: {:ok, t()} | {:error, map()}
  def resolve(raw_context, args) when is_map(raw_context) and is_map(args) do
    workspace_id = fetch(raw_context, :workspace_id)

    cond do
      not is_binary(workspace_id) or workspace_id == "" ->
        {:error,
         %{
           error: :invalid,
           result: :invalid,
           message: "trusted context must include workspace_id"
         }}

      identity_conflict?(args, raw_context) ->
        {:error,
         %{
           error: :denied,
           result: :denied,
           reason: :workspace_scope_mismatch,
           message: "action args may not override trusted workspace/worktree identity"
         }}

      true ->
        {:ok, build(raw_context, workspace_id)}
    end
  end

  def resolve(_raw_context, _args) do
    {:error, %{error: :invalid, result: :invalid, message: "trusted context is required"}}
  end

  @spec authorize_runtime(t()) :: :ok | {:error, map()}
  def authorize_runtime(%{workspace_id: workspace_id} = ctx) do
    if JidoPod.enabled?(workspace_id, runtime: :jido) do
      :ok
    else
      {:error,
       %{
         error: :legacy_opencode,
         result: :denied,
         reason: :legacy_opencode,
         message: "Jido actions are behind the headless feature flag",
         workspace_id: workspace_id,
         correlation_id: Map.get(ctx, :correlation_id)
       }}
    end
  end

  @spec ensure_fresh(t()) :: :ok | {:error, map()}
  def ensure_fresh(%{workspace_id: workspace_id, attempt_id: attempt_id} = ctx)
      when is_binary(attempt_id) and attempt_id != "" do
    case JidoPod.status(workspace_id, attempt_id) do
      {:ok, %{state: :cancelled}} ->
        {:error, stale(:cancelled, ctx, :cancelled)}

      {:ok, %{state: state}} ->
        if Attempt.terminal?(state) do
          {:error, stale(:stale_attempt, ctx, state)}
        else
          :ok
        end

      {:error, :not_found} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  def ensure_fresh(_ctx), do: :ok

  @spec capability_args(map(), [atom()]) :: map()
  def capability_args(args, keys) when is_map(args) and is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch(args, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  @spec fetch(map(), atom()) :: term()
  def fetch(map, key) when is_map(map) and is_atom(key) do
    case PayloadAttrs.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  defp build(raw, workspace_id) do
    task_id = optional(raw, :task_id)
    attempt_id = optional(raw, :attempt_id)
    worktree_path = optional(raw, :worktree_path)
    principal = optional(raw, :principal) || optional(raw, :actor) || optional(raw, :actor_id)
    capability = Map.get(raw, :capability) || fetch(raw, :capability)
    correlation_id = optional(raw, :correlation_id) || attempt_id || task_id

    %{
      workspace_id: workspace_id,
      task_id: task_id,
      attempt_id: attempt_id,
      worktree_path: worktree_path,
      principal: principal,
      capability: capability,
      correlation_id: correlation_id
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp identity_conflict?(args, raw) do
    Enum.any?(@identity_keys, fn key ->
      case {fetch(args, key), fetch(raw, key)} do
        {nil, _} ->
          false

        {_, nil} ->
          false

        {arg, trusted} when key == :worktree_path ->
          canonicalize(arg) != canonicalize(trusted)

        {arg, trusted} ->
          to_string(arg) != to_string(trusted)
      end
    end)
  end

  defp canonicalize(path) when is_binary(path) do
    path |> Path.expand() |> String.trim_trailing("/")
  end

  defp canonicalize(other), do: other

  defp optional(map, key) do
    case fetch(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp stale(kind, ctx, state) do
    %{
      error: kind,
      result: kind,
      state: state,
      message: "attempt is #{state}",
      workspace_id: ctx.workspace_id,
      attempt_id: Map.get(ctx, :attempt_id),
      correlation_id: Map.get(ctx, :correlation_id)
    }
  end
end
