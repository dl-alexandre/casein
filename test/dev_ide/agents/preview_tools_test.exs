defmodule DevIDE.Agents.PreviewToolsTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Agents.PreviewTools
  alias DevIDE.PreviewControl.Registry

  @v3_workspace %{
    id: "ws-tools",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    _ = Registry.clear()
    :ok
  end

  test "definitions exposes narrow agent preview tools" do
    names = PreviewTools.definitions() |> Enum.map(& &1.name)
    assert "preview_open_app" in names
    assert "preview_observe" in names
    assert "preview_screenshot" in names
    assert "preview_close" in names
  end

  test "invoke opens app preview and observes it" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, observation} =
             PreviewTools.invoke("preview_observe", @v3_workspace, %{"session_id" => session_id})

    assert observation.url =~ "alice.devbox.example.com"
  end

  test "invoke closes an open preview session" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, %{session_id: ^session_id, status: :closed}} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{"session_id" => session_id})

    assert {:error, :not_found} =
             PreviewTools.invoke("preview_observe", @v3_workspace, %{"session_id" => session_id})
  end

  test "list_surfaces returns manager surfaces for planning" do
    surfaces = PreviewTools.list_surfaces(@v3_workspace)
    assert Enum.any?(surfaces, &(&1.name == "app"))
  end
end
