defmodule DevIDE.Runners.SafeActionTest do
  use ExUnit.Case, async: true

  alias DevIDE.Commands
  alias DevIDE.Runners.SafeAction

  test "registry is derived from command allowlist and owns argv" do
    by_command =
      SafeAction.all()
      |> Map.new(fn action -> {action.command_id, action} end)

    for {command_id, argv} <- Commands.allowlist() do
      action = Map.fetch!(by_command, command_id)
      assert action.id == "command:" <> command_id
      assert action.argv == argv
      assert action.requires == ["workspace-command:v1"]
    end
  end

  test "unknown actions are not fetchable or compatible" do
    assert :error = SafeAction.fetch("http:proxy")
    assert :error = SafeAction.fetch("command:deploy")
    assert [] = SafeAction.compatible_ids(["http-proxy:v1"])
  end
end
