defmodule DevIDE.PreviewControl.PlaywrightBridgeTest do
  use ExUnit.Case, async: false

  alias DevIDE.PreviewControl.PlaywrightBridge

  setup do
    previous = Application.get_env(:dev_ide, :preview_playwright_script)

    on_exit(fn ->
      put_or_delete_env(:preview_playwright_script, previous)
    end)
  end

  test "returns nil when no helper script is configured" do
    Application.delete_env(:dev_ide, :preview_playwright_script)

    assert PlaywrightBridge.script_path() == nil
  end

  test "resolves repo-style helper paths from the current working directory" do
    Application.put_env(
      :dev_ide,
      :preview_playwright_script,
      "priv/scripts/preview_playwright.mjs"
    )

    assert PlaywrightBridge.script_path() ==
             Path.expand("priv/scripts/preview_playwright.mjs", File.cwd!())
  end

  test "resolves release-style helper paths from the app priv directory" do
    Application.put_env(:dev_ide, :preview_playwright_script, "scripts/preview_playwright.mjs")

    assert PlaywrightBridge.script_path() ==
             :dev_ide
             |> :code.priv_dir()
             |> List.to_string()
             |> Path.join("scripts/preview_playwright.mjs")
  end

  defp put_or_delete_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp put_or_delete_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
