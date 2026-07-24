defmodule Casein.Terminals.SessionTemplate.LoaderSavedTest do
  use Casein.DataCase, async: false

  alias Casein.Terminals.SessionTemplate
  alias Casein.Terminals.SessionTemplate.Loader
  alias Casein.Terminals.Templates

  @ws "ws-saved-1"

  test "list/1 appends saved templates as stubs after the built-ins" do
    # Window 1 has a nested layout tree: a leaf pane plus a split of two
    # leaves -> count_layout_panes = 1 + (1 + 1) = 3 -> two extra pane stubs.
    # Window 2 has no layout -> defaults to a single pane (no extra stubs).
    body = %{
      "version" => 2,
      "windows" => [
        %{
          "name" => "editor",
          "focus" => true,
          "layout" => %{
            "panes" => [
              %{"command" => "vim"},
              %{"panes" => [%{"command" => "a"}, %{"command" => "b"}]}
            ]
          }
        },
        %{"name" => "logs"}
      ]
    }

    assert {:ok, saved} =
             Templates.save(%{
               workspace_id: @ws,
               name: "My Saved Layout",
               description: "A saved export",
               body: body,
               source_session: "devide_ws",
               schema_version: 2
             })

    templates = Loader.list(@ws)

    # Built-ins still present and sorted first.
    builtin_ids = ["agent_pair", "agent_preview_demo", "generic_project", "phoenix_dev"]
    assert Enum.take(Enum.map(templates, & &1.id), 4) == builtin_ids

    stub = Enum.find(templates, &(&1.id == saved.id))
    assert %SessionTemplate{} = stub
    assert stub.name == "My Saved Layout"
    assert stub.description == "A saved export"

    # saved_windows/count_layout_panes built two Window stubs.
    assert length(stub.windows) == 2
    [editor, logs] = stub.windows
    assert editor.name == "editor"
    assert editor.focus == true
    # pane_count 3 -> 2 extra pane stubs
    assert length(editor.panes) == 2
    # window with no layout -> single pane -> no extra stubs
    assert logs.panes == []
  end

  test "list/1 falls back to a default Saved export description when none stored" do
    body = %{"version" => 2, "windows" => [%{"name" => "main"}]}

    {:ok, saved} =
      Templates.save(%{
        workspace_id: @ws,
        name: "No Desc",
        body: body,
        source_session: "devide_ws",
        schema_version: 2
      })

    stub = Loader.list(@ws) |> Enum.find(&(&1.id == saved.id))
    assert stub.description == "Saved export"
  end

  test "list/0 (no workspace) returns only built-ins" do
    assert Enum.map(Loader.list(), & &1.id) ==
             ["agent_pair", "agent_preview_demo", "generic_project", "phoenix_dev"]
  end
end
