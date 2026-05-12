defmodule DevIDE.Fleet.Attach do
  @moduledoc """
  Streaming attach/reconnect helpers for executions.

  Attach is read-oriented: replay durable chunks, subscribe to live execution
  notifications, and include dossier context inline.
  """

  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjectionStore

  @pubsub DevIde.PubSub

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(execution_id) when is_binary(execution_id) do
    Phoenix.PubSub.subscribe(@pubsub, "fleet:executions:#{execution_id}")
  end

  @spec packet(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def packet(execution_id, opts \\ []) when is_binary(execution_id) do
    with {:ok, execution} <- ExecutionProjectionStore.get(execution_id),
         {:ok, dossier} <-
           Fleet.dossier(execution.workspace_id || workspace_id(execution.assignment_id)) do
      if Keyword.get(opts, :subscribe, false), do: subscribe(execution_id)

      {:ok,
       %{
         execution: execution,
         historical_chunks: ArtifactStore.chunks(execution_id),
         live_topic: "fleet:executions:#{execution_id}",
         dossier: dossier
       }}
    else
      :error -> {:error, :execution_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec replay(String.t()) :: [map()]
  def replay(execution_id) when is_binary(execution_id), do: ArtifactStore.chunks(execution_id)

  defp workspace_id(assignment_id) do
    case DevIDE.Assignments.get(assignment_id) do
      {:ok, assignment} -> assignment.workspace_id
      :error -> nil
    end
  end
end
