defmodule DevIDE.Codex.Store do
  @moduledoc """
  Durable query boundary for canonical Codex operations.

  The App Server, JSONL runner, and hook receiver all write the same event
  contract. The store also maintains compact thread and approval projections so
  LiveView never has to replay an unbounded event stream for first paint.
  """

  alias DevIDE.Codex.Event

  @spec record(Event.t()) :: :ok | {:error, term()}
  def record(%Event{} = event), do: impl().record(event)

  @spec latest_sequence(String.t()) :: non_neg_integer()
  def latest_sequence(runtime_id) when is_binary(runtime_id),
    do: impl().latest_sequence(runtime_id)

  @spec workspace_snapshot(String.t(), keyword()) :: map()
  def workspace_snapshot(workspace_id, opts \\ []) when is_binary(workspace_id),
    do: impl().workspace_snapshot(workspace_id, opts)

  @spec timeline(String.t(), String.t(), keyword()) :: [Event.t()]
  def timeline(workspace_id, thread_id, opts \\ [])
      when is_binary(workspace_id) and is_binary(thread_id),
      do: impl().timeline(workspace_id, thread_id, opts)

  @spec clear() :: :ok
  def clear, do: impl().clear()

  defp impl do
    Application.get_env(:dev_ide, :codex_store_adapter, DevIDE.Codex.Store.EctoAdapter)
  end
end
