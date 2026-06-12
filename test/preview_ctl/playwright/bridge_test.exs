defmodule PreviewCtl.Playwright.BridgeTest do
  use ExUnit.Case, async: false

  alias PreviewCtl.Playwright.Bridge

  setup do
    previous = Application.get_env(:preview_ctl, :playwright_script)

    on_exit(fn ->
      put_or_delete_env(previous)
    end)
  end

  test "returns nil when no helper script is configured" do
    Application.delete_env(:preview_ctl, :playwright_script)

    assert Bridge.script_path() == nil
  end

  test "resolves repo-style helper paths from the current working directory" do
    Application.put_env(
      :preview_ctl,
      :playwright_script,
      "priv/scripts/preview_playwright.mjs"
    )

    assert Bridge.script_path() ==
             Path.expand("priv/scripts/preview_playwright.mjs", File.cwd!())
  end

  test "resolves release-style helper paths from the app priv directory" do
    Application.put_env(:preview_ctl, :playwright_script, "scripts/preview_playwright.mjs")

    assert Bridge.script_path() ==
             :dev_ide
             |> :code.priv_dir()
             |> List.to_string()
             |> Path.join("scripts/preview_playwright.mjs")
  end

  defp put_or_delete_env(nil), do: Application.delete_env(:preview_ctl, :playwright_script)

  defp put_or_delete_env(value),
    do: Application.put_env(:preview_ctl, :playwright_script, value)
end
