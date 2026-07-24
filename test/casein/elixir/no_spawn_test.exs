defmodule Casein.Elixir.NoSpawnTest do
  @moduledoc """
  Boundary guard: M17 may detect Lexical/ElixirLS, but must never start one.
  No `Port.open` / `System.cmd("lexical")` / `:exec.run` paths in this subsystem.
  """
  use Casein.TestCase, async: true

  @sources [
    "lib/casein/elixir.ex",
    "lib/casein/elixir/symbol.ex",
    "lib/casein/elixir/symbols.ex",
    "lib/casein/elixir/project.ex",
    "lib/casein/elixir/tooling.ex"
  ]

  test "no source spawns Lexical/ElixirLS or runs mix" do
    for rel <- @sources do
      src = File.read!(Path.expand(rel, File.cwd!()))

      refute src =~ ~r/Port\.open/, "Port.open in #{rel}"
      refute src =~ ~r/:exec\.run/, ":exec.run in #{rel}"

      refute src =~ ~r/System\.cmd\(["'](?:lexical|elixir-ls|elixir_ls|mix)/,
             "System.cmd spawning lexical/elixir-ls/mix in #{rel}"
    end
  end
end
