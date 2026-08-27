defmodule Casein.Agents.JidoActions.Context do
  @moduledoc """
  Trusted invocation identity for typed Jido worker actions.

  Workspace, task, attempt, worktree, principal, capability profile, and
  correlation come from the caller-supplied context (the pod/attempt), never
  from model-authored tool arguments. Conflicting identity in args is a deny.
  """

  alias Casein.Agents.JidoPod
  alias Casein.Agents.JidoPod.Attempt
  alias Casein.Agents.JidoWorkcell.{Limits, OwnerRef}
  alias Casein.PayloadAttrs

  @type t :: %{
          required(:workspace_id) => String.t(),
          optional(:task_id) => String.t(),
          optional(:attempt_id) => String.t(),
          optional(:session_id) => String.t(),
          optional(:workcell_id) => String.t(),
          optional(:workcell_assigned?) => boolean(),
          optional(:source) => String.t(),
          optional(:worker_id) => String.t(),
          optional(:runtime_id) => String.t(),
          optional(:owner_ref) => OwnerRef.t(),
          optional(:release_sha) => String.t(),
          optional(:lease_id) => String.t(),
          optional(:handoff_id) => String.t(),
          optional(:receipt_id) => String.t(),
          optional(:evidence_ref) => String.t(),
          optional(:decision_id) => String.t(),
          optional(:origin) => atom() | String.t(),
          optional(:lane) => atom() | String.t(),
          optional(:worktree_path) => String.t(),
          optional(:git_scope) => struct() | nil,
          optional(:base_branch) => String.t(),
          optional(:head_branch) => String.t(),
          optional(:repository) => String.t(),
          optional(:principal) => String.t(),
          optional(:capability) => atom() | String.t(),
          optional(:correlation_id) => String.t()
        }

  @identity_keys [
    :workspace_id,
    :task_id,
    :attempt_id,
    :session_id,
    :workcell_id,
    :workcell_assigned?,
    :source,
    :worker_id,
    :runtime_id,
    :owner_ref,
    :release_sha,
    :lease_id,
    :correlation_id,
    :receipt_id,
    :evidence_ref,
    :decision_id,
    :worktree_path,
    :git_scope
  ]

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

      not Limits.workspace_allowed?(workspace_id) ->
        {:error,
         %{
           error: :denied,
           result: :denied,
           reason: :workspace_not_allowed,
           workspace_id: workspace_id,
           message: "workspace is not in the Jido Workcell allowlist"
         }}

      Limits.validate_input(args) != :ok ->
        {:error,
         %{
           error: :invalid,
           result: :invalid,
           reason: :input_too_large,
           message: "Jido action input exceeds CASEIN_INPUT_MAX_BYTES (8192)"
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
    session_id = optional(raw, :session_id)
    workcell_id = optional(raw, :workcell_id)
    workcell_assigned? = fetch(raw, :workcell_assigned?) == true
    source = optional(raw, :source)
    worker_id = optional(raw, :worker_id)
    runtime_id = optional(raw, :runtime_id)
    owner_ref = optional(raw, :owner_ref)
    release_sha = optional(raw, :release_sha)
    lease_id = optional(raw, :lease_id)
    handoff_id = optional(raw, :handoff_id)
    receipt_id = optional(raw, :receipt_id)
    evidence_ref = optional(raw, :evidence_ref)
    decision_id = optional(raw, :decision_id)
    worktree_path = optional(raw, :worktree_path)
    principal = optional(raw, :principal) || optional(raw, :actor) || optional(raw, :actor_id)
    capability = Map.get(raw, :capability) || fetch(raw, :capability)
    correlation_id = optional(raw, :correlation_id)
    origin = raw |> fetch(:origin) |> normalize_marker()
    lane = raw |> fetch(:lane) |> normalize_marker()

    %{
      workspace_id: workspace_id,
      task_id: task_id,
      attempt_id: attempt_id,
      session_id: session_id,
      workcell_id: workcell_id,
      workcell_assigned?: workcell_assigned?,
      source: source,
      worker_id: worker_id,
      runtime_id: runtime_id,
      owner_ref: owner_ref,
      release_sha: release_sha,
      lease_id: lease_id,
      handoff_id: handoff_id,
      receipt_id: receipt_id,
      evidence_ref: evidence_ref,
      decision_id: decision_id,
      origin: origin,
      lane: lane,
      worktree_path: worktree_path,
      git_scope: fetch(raw, :git_scope),
      base_branch: optional(raw, :base_branch),
      head_branch: optional(raw, :head_branch),
      repository: optional(raw, :repository),
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

        {arg, trusted} when key == :git_scope ->
          arg != trusted

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
      value when key == :owner_ref and is_map(value) ->
        case OwnerRef.normalize(value) do
          {:ok, owner_ref} -> owner_ref
          {:error, _reason} -> nil
        end

      value when is_binary(value) and value != "" ->
        value

      _ ->
        nil
    end
  end

  defp normalize_marker(value) when is_atom(value), do: value
  defp normalize_marker(value) when is_binary(value) and value != "", do: value
  defp normalize_marker(_value), do: nil

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
