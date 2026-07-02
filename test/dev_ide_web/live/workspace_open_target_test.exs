defmodule DevIdeWeb.WorkspaceOpenTargetTest do
  use DevIDE.TestCase, async: true

  import Phoenix.Component, only: [assign: 3]

  alias DevIDE.Workspace
  alias DevIdeWeb.WorkspaceLive.Show

  setup do
    root =
      Path.join(System.tmp_dir!(), "workspace-open-target-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "docs/readme.md"), "# Readme\n\nSee [code](../lib/foo.ex).\n")
    File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo do\n  def ok, do: :ok\nend\n")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  test "open target markdown opens the file viewer in rendered mode", %{root: root} do
    {:noreply, socket} =
      Show.handle_info(
        {:open_target, {:markdown, %{path: "docs/readme.md", anchor: nil}}},
        socket(root)
      )

    assert socket.assigns.tab == "files"
    assert socket.assigns.open_file.path == "docs/readme.md"
    assert socket.assigns.file_render_mode == "rendered"

    assert [["file:loaded", payload]] = push_events(socket)
    assert payload.path == "docs/readme.md"
    assert payload.markdown == true
    assert payload.render_mode == "rendered"
    assert payload.rendered_html =~ "/api/workspaces/ws-open/files/lib/foo.ex"
  end

  test "open target file opens the editor at the requested line", %{root: root} do
    {:noreply, socket} =
      Show.handle_info(
        {:open_target, {:file, %{path: "lib/foo.ex", line: 2, col: nil}}},
        socket(root)
      )

    assert socket.assigns.tab == "files"
    assert socket.assigns.open_file.path == "lib/foo.ex"
    assert socket.assigns.file_render_mode == "source"

    assert [["file:loaded", payload]] = push_events(socket)
    assert payload.path == "lib/foo.ex"
    assert payload.markdown == false
    assert payload.render_mode == "source"
    assert payload.line == 2
  end

  test "open target external URL flashes instead of navigating", %{root: root} do
    {:noreply, socket} =
      Show.handle_info(
        {:open_target, {:external, %{url: "https://example.com/docs"}}},
        socket(root)
      )

    assert socket.assigns.flash["info"] == "External link requested: https://example.com/docs"
    assert push_events(socket) == []
  end

  defp socket(root) do
    workspace = %Workspace{
      id: "ws-open",
      name: "ws-open",
      path: root,
      status: :running,
      metadata: %{attached_folder: true}
    }

    %Phoenix.LiveView.Socket{}
    |> assign(:workspace, workspace)
    |> assign(:host_path, {:ok, root})
    |> assign(:host_loc, {:ok, {:local, root}})
    |> assign(:tab, "terminal")
    |> assign(:open_file, nil)
    |> assign(:file_render_mode, nil)
    |> assign(:file_error, nil)
    |> assign(:save_error, nil)
    |> assign(:file_diff, nil)
    |> assign(:tree, %{})
    |> assign(:selected_dir, "")
    |> put_test_flash()
  end

  defp push_events(socket) do
    socket.private.live_temp[:push_events] || []
  end

  defp put_test_flash(socket) do
    put_in(socket.assigns[:flash], %{})
  end
end
