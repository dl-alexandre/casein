defmodule Casein.SearchNoReplaceTest do
  @moduledoc """
  Boundary guard: M18 is search-only. No replace, no write, no shell-string
  invocation of `rg`. The argv-only path is the only path.
  """
  use Casein.TestCase, async: true

  @sources [
    "lib/casein/search.ex",
    "lib/casein/search/adapter.ex",
    "lib/casein/search/result.ex",
    "lib/casein/search/ripgrep_adapter.ex",
    "lib/casein/search/memory_adapter.ex"
  ]

  test "Search behaviour exposes only search and available?" do
    callbacks =
      Casein.Search.Adapter.behaviour_info(:callbacks)
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
