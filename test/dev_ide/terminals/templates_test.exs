defmodule DevIDE.Terminals.TemplatesTest do
  use DevIde.DataCase, async: true

  alias DevIDE.Terminals.Templates

  test "saves and lists exported templates by workspace" do
    body = %{
      "version" => 2,
      "name" => "saved_layout",
      "windows" => [
        %{"name" => "server", "layout" => %{"name" => "mix"}},
        %{"name" => "tests", "layout" => %{"direction" => "tiled", "panes" => []}}
      ]
    }

    assert {:ok, saved} =
             Templates.save(%{
               workspace_id: "ws-1",
               name: "saved_layout",
               description: "A saved export",
               body: body,
               source_session: "devide_ws",
               schema_version: 2
             })

    assert saved.id
    assert saved.workspace_id == "ws-1"
    assert saved.name == "saved_layout"
    assert saved.description == "A saved export"
    assert saved.body == body
    assert saved.source_session == "devide_ws"
    assert saved.schema_version == 2
    assert %DateTime{} = saved.inserted_at

    assert [listed] = Templates.list_for_workspace("ws-1")
    assert listed.id == saved.id
    assert Templates.list_for_workspace("ws-2") == []

    assert {:ok, fetched} = Templates.get("ws-1", saved.id)
    assert fetched.id == saved.id
    assert {:error, :not_found} = Templates.get("ws-2", saved.id)
  end

  test "validates required saved template fields" do
    assert {:error, changeset} = Templates.save(%{workspace_id: "ws-1", body: %{}})
    assert %{name: ["can't be blank"]} = errors_on(changeset)
  end
end
