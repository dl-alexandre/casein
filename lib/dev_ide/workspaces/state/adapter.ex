defmodule DevIDE.Workspaces.State.Adapter do
  @moduledoc "Behaviour for workspace record persistence adapters."

  alias DevIDE.Workspaces.State.WorkspaceRecord

  @callback upsert(WorkspaceRecord.t()) :: {:ok, WorkspaceRecord.t()} | {:error, term()}
  @callback upsert_all([WorkspaceRecord.t()]) :: {:ok, [WorkspaceRecord.t()]} | {:error, term()}
  @callback get(external_id :: String.t()) :: {:ok, WorkspaceRecord.t()} | :error
  @callback get_many(external_ids :: [String.t()]) ::
              %{optional(String.t()) => WorkspaceRecord.t()}
  @callback list() :: [WorkspaceRecord.t()]
  @callback delete(external_id :: String.t()) :: :ok
end
