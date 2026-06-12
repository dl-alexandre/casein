defmodule DevIDE.PreviewControl.Registry do
  @moduledoc false

  defdelegate start_link(opts \\ []), to: PreviewCtl.Registry
  defdelegate put(session_id, entry), to: PreviewCtl.Registry
  defdelegate get(session_id), to: PreviewCtl.Registry
  defdelegate update(session_id, fun), to: PreviewCtl.Registry
  defdelegate delete(session_id), to: PreviewCtl.Registry
  defdelegate clear(), to: PreviewCtl.Registry
end
