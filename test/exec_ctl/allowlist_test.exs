defmodule ExecCtl.AllowlistTest do
  use ExUnit.Case, async: true

  alias ExecCtl.Allowlist

  test "all/0 exposes stable palette command ids" do
    ids = Allowlist.all() |> Map.keys() |> Enum.sort()

    assert ids == [
             "agent",
             "assets.build",
             "claude",
             "clauded",
             "codex",
             "compile",
             "dogfood.fail",
             "format",
             "grok",
             "opencode",
             "precommit",
             "test"
           ]
  end

  test "allowed?/1 and argv_for/1" do
    assert Allowlist.allowed?("test")
    refute Allowlist.allowed?("rm -rf /")

    assert {:ok, ["mix", "test", "--color"]} = Allowlist.argv_for("test")
    assert :error = Allowlist.argv_for("unknown")
  end

  test "dogfood.fail argv exits with a non-zero status when run" do
    assert {:ok, argv} = Allowlist.argv_for("dogfood.fail")
    assert ["mix", "run", "-e", _] = argv
  end
end
