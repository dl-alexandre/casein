defmodule DevIDE.PreviewControl.MemoryAdapter do
  @moduledoc """
  DevIDE facade over `PreviewCtl.Test.FakeAdapter` for tests and local development.
  """

  @behaviour DevIDE.PreviewControl.Adapter

  defdelegate start_session(session), to: PreviewCtl.Test.FakeAdapter
  defdelegate navigate(state, url), to: PreviewCtl.Test.FakeAdapter
  defdelegate observe(state), to: PreviewCtl.Test.FakeAdapter
  defdelegate observe_live(state), to: PreviewCtl.Test.FakeAdapter
  defdelegate click(state, target), to: PreviewCtl.Test.FakeAdapter
  defdelegate type(state, selector, text), to: PreviewCtl.Test.FakeAdapter
  defdelegate press(state, key), to: PreviewCtl.Test.FakeAdapter
  defdelegate screenshot(state), to: PreviewCtl.Test.FakeAdapter
  defdelegate get_storage(state), to: PreviewCtl.Test.FakeAdapter
  defdelegate close(state), to: PreviewCtl.Test.FakeAdapter
end
