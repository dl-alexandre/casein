defmodule Casein.Export do
  @moduledoc "Public facade for the read-only status export API."

  defdelegate list_summary(), to: Casein.Export.WorkspaceStatus
  defdelegate status(id), to: Casein.Export.WorkspaceStatus
  defdelegate runs(id), to: Casein.Export.WorkspaceStatus
  defdelegate run(id, run_id), to: Casein.Export.WorkspaceStatus
  defdelegate proposals(id), to: Casein.Export.WorkspaceStatus
  defdelegate audit(id), to: Casein.Export.WorkspaceStatus
  defdelegate previous_sessions(id, opts \\ []), to: Casein.Export.WorkspaceStatus
end
