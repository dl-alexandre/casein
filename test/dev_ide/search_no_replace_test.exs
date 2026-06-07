defmodule DevIDE.SearchNoReplaceTest do
  @moduledoc """
  Boundary guard: M18 is search-only. No replace, no write, no shell-string
  invocation of `rg`. The argv-only path is the only path.
  """
  use ExUnit.Case, async: true

  @sources [
    "lib/dev_ide/search.ex",
    "lib/dev_ide/search/adapter.ex",
    "lib/dev_ide/search/result.ex",
    "lib/dev_ide/search/ripgrep_adapter.ex",
    "lib/dev_ide/search/memory_adapter.ex"
  ]

  test "Search behaviour exposes only search and available?" do
    callbacks =
      DevIDE.Search.Adapter.behaviour_info(:callbacks)
      |> Enum.map(fn {n, _} -> n end)
      |> Enum.sort()

    assert callbacks == [:available?, :search]
  end

  test "no source contains a replace/write path" do
    for rel <- @sources do
      src = File.read!(Path.expand(rel, File.cwd!()))

      refute src =~ ~r/--replace/, "rg --replace flag in #{rel}"
      refute src =~ ~r/File\.(write|cp|rename|rm)\b/, "write call in #{rel}"
      refute src =~ ~r/Port\.open/, "Port.open in #{rel}"
      refute src =~ ~r/:exec\.run/, ":exec.run in #{rel}"
      # rg must be invoked through System.cmd with argv list, not a shell string
      refute src =~ ~r/System\.cmd\([^,]+,\s*"/, "System.cmd with shell-string in #{rel}"
    end
  end
end
