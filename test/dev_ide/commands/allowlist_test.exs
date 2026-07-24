defmodule Casein.Commands.AllowlistTest do
  use Casein.TestCase, async: true

  alias Casein.Commands.Allowlist
  alias ExecCtl.Allowlist, as: CtlAllowlist

  test "facade delegates to ExecCtl.Allowlist" do
    assert Allowlist.all() == CtlAllowlist.all()
    assert Allowlist.allowed?("compile") == CtlAllowlist.allowed?("compile")
    assert Allowlist.argv_for("format") == CtlAllowlist.argv_for("format")
  end
end
