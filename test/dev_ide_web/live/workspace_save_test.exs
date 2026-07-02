defmodule DevIdeWeb.WorkspaceSaveTest do
  @moduledoc """
  LiveView-level safety: the file:save handler must refuse a payload whose
  `path`/`version` pair does not match `socket.assigns.open_file`. We exercise
  the handler directly instead of routing through the full LiveView so the
  test stays focused.
  """
  use DevIDE.TestCase, async: false
  alias DevIdeWeb.WorkspaceLive.Show

  setup do
    root = Path.join(System.tmp_dir!(), "lvsave-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "1\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "refuses save with stale version even if path matches", %{root: root} do
    {:ok, file} = DevIDE.Files.read_text(root, "a.txt")

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:host_path, {:ok, root})
      |> Phoenix.Component.assign(:open_file, file)
      |> Phoenix.Component.assign(:save_error, nil)
      |> Phoenix.Component.assign(:git_status, [])
      |> Phoenix.Component.assign(:file_diff, nil)
      |> Phoenix.Component.assign(:workspace, %{id: "ws"})

    payload = %{"path" => "a.txt", "content" => "2\n", "version" => "stale-version-token"}
    {:noreply, new_socket} = Show.handle_event("file:save", payload, socket)

    assert new_socket.assigns.save_error =~ "Save aborted" or
             new_socket.assigns.save_error =~ "Conflict"

    assert File.read!(Path.join(root, "a.txt")) == "1\n"
  end

  test "refuses save with mismatched path", %{root: root} do
    {:ok, file} = DevIDE.Files.read_text(root, "a.txt")

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:host_path, {:ok, root})
      |> Phoenix.Component.assign(:open_file, file)
      |> Phoenix.Component.assign(:save_error, nil)
      |> Phoenix.Component.assign(:git_status, [])
      |> Phoenix.Component.assign(:file_diff, nil)
      |> Phoenix.Component.assign(:workspace, %{id: "ws"})

    payload = %{"path" => "../escape", "content" => "x", "version" => file.version}
    {:noreply, new_socket} = Show.handle_event("file:save", payload, socket)

    assert new_socket.assigns.save_error
    assert File.read!(Path.join(root, "a.txt")) == "1\n"
  end
end
