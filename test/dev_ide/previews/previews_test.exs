defmodule DevIDE.PreviewsTest do
  use DevIde.DataCase, async: true

  alias DevIDE.Previews
  alias DevIDE.Previews.Preview

  @workspace %{id: "ws-1"}

  test "open/1 persists workspace string ids and trusted localhost URLs" do
    assert {:ok, %Preview{} = preview} =
             Previews.open(@workspace, %{url: "http://localhost:4000", mode: :iframe})

    assert preview.workspace_id == "ws-1"
    assert preview.trusted
    assert preview.status == :open
  end

  test "is_trusted_url?/1 normalizes loopback hosts like the detector" do
    assert Previews.is_trusted_url?("http://0.0.0.0:3000")
    assert Previews.is_trusted_url?("http://127.0.0.1:5173")
    refute Previews.is_trusted_url?("http://evil.example:4000")
  end

  test "close/1 marks preview closed and drops it from open list" do
    {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:5173"})

    assert {:ok, %Preview{status: :closed}} = Previews.close(preview)
    assert Previews.list_for_workspace("ws-1") == []
  end

  test "get_for_workspace/2 scopes by workspace id" do
    {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:8080"})
    assert %Preview{} = Previews.get_for_workspace(preview.id, "ws-1")
    assert Previews.get_for_workspace(preview.id, "ws-2") == nil
  end

  test "rejects non-localhost preview URLs" do
    assert {:error, %Ecto.Changeset{}} =
             Previews.open(@workspace, %{url: "http://evil.example:4000"})
  end
end
