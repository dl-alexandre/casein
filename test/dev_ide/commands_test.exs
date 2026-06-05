defmodule DevIDE.CommandsTest do
  use ExUnit.Case, async: true
  alias DevIDE.Commands

  test "allowlist exposes only safe command ids" do
    assert Map.keys(Commands.allowlist()) |> Enum.sort() ==
             ~w(agent assets.build claude clauded codex compile dogfood.fail format grok opencode precommit test)
             |> Enum.sort()
  end

  test "allowed?/1 only accepts allowlist ids" do
    assert Commands.allowed?("test")
    refute Commands.allowed?("rm -rf /")
    refute Commands.allowed?("compile; echo pwned")
  end

  test "argv_for/1 returns argv lists, never strings to be shell-parsed" do
    {:ok, argv} = Commands.argv_for("test")
    assert is_list(argv)
    assert Enum.all?(argv, &is_binary/1)
  end
end
