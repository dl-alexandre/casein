defmodule DevIDE.PreviewControl.PlaywrightAdapter do
  @moduledoc """
  DevIDE facade over `PreviewCtl.Playwright.Adapter`.
  """

  @behaviour DevIDE.PreviewControl.Adapter

  defdelegate start_session(session), to: PreviewCtl.Playwright.Adapter
  defdelegate navigate(state, url), to: PreviewCtl.Playwright.Adapter
  defdelegate observe(state), to: PreviewCtl.Playwright.Adapter
  defdelegate observe_live(state), to: PreviewCtl.Playwright.Adapter
  defdelegate click(state, target), to: PreviewCtl.Playwright.Adapter
  defdelegate type(state, selector, text), to: PreviewCtl.Playwright.Adapter
  defdelegate press(state, key), to: PreviewCtl.Playwright.Adapter
  defdelegate screenshot(state), to: PreviewCtl.Playwright.Adapter
  defdelegate get_storage(state), to: PreviewCtl.Playwright.Adapter
  defdelegate clear_storage(state), to: PreviewCtl.Playwright.Adapter
  defdelegate close(state), to: PreviewCtl.Playwright.Adapter
end
