defmodule DevIDE.Workspaces.IsolationProbe do
  @moduledoc "Behaviour for read-only DB isolation detection."

  alias DevIDE.Workspaces.DbIsolation

  @callback detect(workspace :: map(), root :: String.t()) :: DbIsolation.t()
end
