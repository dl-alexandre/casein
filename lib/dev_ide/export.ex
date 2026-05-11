defmodule DevIDE.Export do
  @moduledoc "Public facade for the read-only status export API."

  defdelegate list_summary(), to: DevIDE.Export.WorkspaceStatus
  defdelegate status(id), to: DevIDE.Export.WorkspaceStatus
  defdelegate runs(id), to: DevIDE.Export.WorkspaceStatus
  defdelegate proposals(id), to: DevIDE.Export.WorkspaceStatus
  defdelegate audit(id), to: DevIDE.Export.WorkspaceStatus
end
