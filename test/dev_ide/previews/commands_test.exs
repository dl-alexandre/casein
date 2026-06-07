defmodule DevIDE.Previews.CommandsTest do
  use DevIde.DataCase, async: false

  alias DevIDE.PreviewControl.Registry
  alias DevIDE.Previews.Commands

  @v3_workspace %{
    id: "ws-cmd",
    metadata: %{
      type: :v3,
      domain_base: "demo.devbox.example.com",
      ports: %{"http" => 10_405}
    }
  }

  setup do
    _ = Registry.clear()
    :ok
  end

  test "preview surfaces lists manager surfaces" do
    assert {:ok, %{output: output}} =
             Commands.run(@v3_workspace, "preview surfaces", ["preview", "surfaces"])

    assert output =~ "app"
    assert output =~ "app-local"
    assert output =~ "localhost:10405"
  end

  test "preview open starts a control session" do
    assert {:ok, %{output: output}} =
             Commands.run(@v3_workspace, "preview open app", ["preview", "open", "app"],
               actor_id: "agent-1"
             )

    assert output =~ "session_id:"
    assert output =~ "demo.devbox.example.com"
  end
end
