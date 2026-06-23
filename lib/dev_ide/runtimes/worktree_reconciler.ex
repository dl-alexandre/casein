defmodule DevIDE.Runtimes.WorktreeReconciler do
  @moduledoc """
  Cached reconciliation for Git worktrees attached to a workspace checkout.

  `DevIDE.Runtimes.discover_worktrees/1` is the low-level, shelling primitive.
  This module is the UI/control-plane boundary: it keeps discovery explicit,
  rate-limited, and inspectable.
  """

  alias DevIDE.Runtimes

  @cache_key {__MODULE__, :cache}
  @default_ttl_ms 15_000

  @type status :: %{
          workspace_id: String.t(),
          status: :ok | :error,
          observed_count: non_neg_integer(),
          expired_count: non_neg_integer(),
          rejected_count: non_neg_integer(),
          error: term(),
          reconciled_at: DateTime.t(),
          monotonic_at: integer()
        }

  @doc "Reconcile a workspace's linked Git worktrees unless the cached status is fresh."
  @spec reconcile(String.t(), keyword()) :: {:ok, status()} | {:error, term()}
  def reconcile(workspace_id, opts \\ [])

  def reconcile(workspace_id, opts) when is_binary(workspace_id) do
    force? = Keyword.get(opts, :force, false)
    ttl_ms = Keyword.get(opts, :ttl_ms, ttl_ms())
    now = System.monotonic_time(:millisecond)

    case {force?, lookup(workspace_id)} do
      {false, {:ok, cached}} when now - cached.monotonic_at <= ttl_ms ->
        return_status(cached)

      _ ->
        do_reconcile(workspace_id)
    end
  end

  def reconcile(_workspace_id, _opts), do: {:error, :invalid_workspace_id}

  @doc "Force reconcile and return active agent worktree payloads."
  @spec refresh_agent_worktrees(String.t()) :: [map()]
  def refresh_agent_worktrees(workspace_id) when is_binary(workspace_id) do
    _ = reconcile(workspace_id, force: true)
    Runtimes.list_agent_worktrees(workspace_id)
  end

  def refresh_agent_worktrees(_workspace_id), do: []

  @doc "Reconcile using the cache, then return active agent worktree payloads."
  @spec list_agent_worktrees(String.t(), keyword()) :: [map()]
  def list_agent_worktrees(workspace_id, opts \\ [])

  def list_agent_worktrees(workspace_id, opts) when is_binary(workspace_id) do
    _ = reconcile(workspace_id, opts)
    Runtimes.list_agent_worktrees(workspace_id)
  end

  def list_agent_worktrees(_workspace_id, _opts), do: []

  @doc "Return the last cached reconciliation status for a workspace."
  @spec status(String.t()) :: {:ok, status()} | :error
  def status(workspace_id) when is_binary(workspace_id) do
    lookup(workspace_id)
  end

  def status(_workspace_id), do: :error

  @doc "Clear the in-memory reconciliation cache."
  @spec clear() :: :ok
  def clear do
    :persistent_term.put(@cache_key, %{})
    :ok
  end

  defp do_reconcile(workspace_id) do
    status =
      case discover(workspace_id) do
        {:ok, result} ->
          observed = Map.get(result, :observed, [])
          expired = Map.get(result, :expired, [])
          rejected = Map.get(result, :rejected, [])

          new_status(workspace_id, :ok,
            observed_count: length(observed),
            expired_count: length(expired),
            rejected_count: length(rejected),
            error: nil
          )

        {:error, reason} ->
          new_status(workspace_id, :error, error: reason)

        other ->
          new_status(workspace_id, :error, error: {:unexpected_discovery_result, other})
      end

    put_status(workspace_id, status)
    return_status(status)
  end

  defp return_status(%{status: :ok} = status), do: {:ok, status}
  defp return_status(%{status: :error, error: error}), do: {:error, error}

  defp discover(workspace_id), do: apply(Runtimes, :discover_worktrees, [workspace_id])

  defp new_status(workspace_id, status, opts) do
    %{
      workspace_id: workspace_id,
      status: status,
      observed_count: Keyword.get(opts, :observed_count, 0),
      expired_count: Keyword.get(opts, :expired_count, 0),
      rejected_count: Keyword.get(opts, :rejected_count, 0),
      error: Keyword.get(opts, :error),
      reconciled_at: DateTime.utc_now(),
      monotonic_at: System.monotonic_time(:millisecond)
    }
  end

  defp lookup(workspace_id) do
    case Map.fetch(cache(), workspace_id) do
      {:ok, status} -> {:ok, status}
      :error -> :error
    end
  end

  defp put_status(workspace_id, status) do
    cache =
      @cache_key
      |> :persistent_term.get(%{})
      |> Map.put(workspace_id, status)

    :persistent_term.put(@cache_key, cache)
  end

  defp cache, do: :persistent_term.get(@cache_key, %{})

  defp ttl_ms do
    Application.get_env(:dev_ide, :worktree_reconcile_ttl_ms, @default_ttl_ms)
  end
end
