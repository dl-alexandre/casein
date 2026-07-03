defmodule DevIdeWeb.WorkspaceLive.Show.PaletteItemsTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter
  alias DevIdeWeb.WorkspaceLive.Show.PaletteItems

  setup do
    MemoryAdapter.clear()

    root =
      Path.join(
        System.tmp_dir!(),
        "palette-items-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".dev_ide/workflows"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "palette lists runnable repository workflows", %{root: root} do
    write_workflow(root, "precommit.yaml", """
    name: Precommit
    description: Full precommit gate
    command: mix precommit
    """)

    socket = palette_socket(root, "ws-palette")

    items = PaletteItems.query(socket, "precommit")

    assert Enum.any?(items, fn item ->
             item.id == "workflow:run:precommit" and
               item.label == "Run Precommit" and
               String.contains?(item.detail, "Full precommit gate")
           end)
  end

  test "palette resolves runnable workflows to workflow:run", %{root: root} do
    write_workflow(root, "compile.yaml", """
    name: Compile
    description: Compile only
    command: mix compile
    """)

    socket = palette_socket(root, "ws-palette")

    assert {:ok, %{event: "workflow:run", params: %{"command-id" => command_id}}} =
             PaletteItems.resolve(socket, root, "workflow:run:compile")

    assert String.starts_with?(command_id, "workflow:")
  end

  test "parameterized workflows appear as hints, not runnable", %{root: root} do
    write_workflow(root, "focused-test.yaml", """
    name: Focused test
    description: One file
    command: mix test {{test_file}}
    arguments:
      - name: test_file
    """)

    socket = palette_socket(root, "ws-palette")

    items = PaletteItems.query(socket, "focused")

    assert Enum.any?(items, fn item ->
             item.id == "workflow:hint:focused-test" and
               String.contains?(item.detail, "type this in the command line")
           end)

    refute Enum.any?(items, &String.starts_with?(&1.id, "workflow:run:"))

    assert {:ok, %{event: "workflow:hint", params: %{}}} =
             PaletteItems.resolve(socket, root, "workflow:hint:focused-test")

    assert :error = PaletteItems.resolve(socket, root, "workflow:run:focused-test")
  end

  test "palette lists preview surface items from detected ports", %{root: root} do
    socket = preview_socket(root, "ws-palette-preview")

    items = PaletteItems.query(socket, "8765")

    assert Enum.any?(items, fn item ->
             item.id == "preview:surface:localhost:8765" and
               item.category == :preview and
               item.label == "Preview: Open localhost:8765" and
               item.payload == %{
                 event: "preview:open",
                 params: %{"surface" => "localhost:8765", "mode" => "tab"}
               }
           end)
  end

  test "resolve validates preview surfaces against the workspace", %{root: root} do
    socket = preview_socket(root, "ws-palette-preview")

    assert {:ok,
            %{event: "preview:open", params: %{"surface" => "localhost:8765", "mode" => "tab"}}} =
             PaletteItems.resolve(socket, root, "preview:surface:localhost:8765")

    assert :error = PaletteItems.resolve(socket, root, "preview:surface:localhost:9999")
  end

  defp preview_socket(root, workspace_id) do
    socket = palette_socket(root, workspace_id)

    %{
      socket
      | assigns:
          Map.merge(socket.assigns, %{
            palette_category: :preview,
            workspace: %{id: workspace_id, metadata: %{detected_ports: [8765]}}
          })
    }
  end

  defp palette_socket(root, workspace_id) do
    {:ok, _} =
      State.sync(%Workspace{
        id: workspace_id,
        name: "palette-test",
        user: "alice",
        branch: "main",
        status: :running,
        path: root,
        metadata: %{}
      })

    %{
      assigns: %{
        workspace: %{id: workspace_id},
        host_path: {:ok, root},
        palette_category: :commands,
        terminal_mode: :raw,
        session_tabs: [],
        tmux_panes: [],
        tmux_window_tabs: []
      }
    }
  end

  defp write_workflow(root, name, body) do
    dir = Path.join(root, ".dev_ide/workflows")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), body)
  end
end
