defmodule DevIDE.JXBoundaryTest do
  use ExUnit.Case, async: true

  test "DevIDE modules do not depend on JX adapter modules" do
    offenders =
      ["lib/dev_ide", "lib/dev_ide_web"]
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> String.contains?("JX.")
      end)

    assert offenders == []
  end
end
