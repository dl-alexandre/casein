defmodule DevIDE.PreviewControl.PlaywrightBridge do
  @moduledoc false

  defdelegate start_link(opts \\ []), to: PreviewCtl.Playwright.Bridge
  defdelegate command(payload), to: PreviewCtl.Playwright.Bridge
  defdelegate script_path(), to: PreviewCtl.Playwright.Bridge
end
