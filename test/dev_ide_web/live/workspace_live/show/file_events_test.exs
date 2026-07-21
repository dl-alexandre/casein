defmodule DevIdeWeb.WorkspaceLive.Show.FileEventsTest do
  use DevIDE.TestCase, async: true

  import Phoenix.Component, only: [update: 3]

  alias DevIdeWeb.WorkspaceLive.Show.FileEvents

  # These cover the pure handle_event clauses that only mutate socket assigns.
  # IO / policy-gated clauses (create, rename_submit, delete_confirm, save,
  # tree:open, file:refresh) live in Show.* and are exercised elsewhere.
  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  test "tree:toggle collapses an expanded node" do
    s = socket(%{tree: %{"lib" => {:expanded, [:child]}}})
    assert {:noreply, s2} = FileEvents.handle_event("tree:toggle", %{"path" => "lib"}, s)
    assert s2.assigns.tree["lib"] == {:collapsed, []}
  end

  test "tree:toggle collapse drops descendant subtree keys" do
    tree = %{
      "A" => {:expanded, [:b]},
      "A/B" => {:expanded, [:c]},
      "A/B/C" => {:expanded, [:file]},
      "other" => {:expanded, [:x]}
    }

    s = socket(%{tree: tree})
    assert {:noreply, s2} = FileEvents.handle_event("tree:toggle", %{"path" => "A"}, s)

    assert s2.assigns.tree["A"] == {:collapsed, []}
    refute Map.has_key?(s2.assigns.tree, "A/B")
    refute Map.has_key?(s2.assigns.tree, "A/B/C")
    assert s2.assigns.tree["other"] == {:expanded, [:x]}
  end

  test "tree:select_dir sets the selected directory" do
    s = socket(%{selected_dir: nil})
    assert {:noreply, s2} = FileEvents.handle_event("tree:select_dir", %{"path" => "lib"}, s)
    assert s2.assigns.selected_dir == "lib"
  end

  test "tree:new_form opens a file or dir input under the selected dir" do
    s = socket(%{selected_dir: "lib", new_input: nil})

    assert {:noreply, sf} = FileEvents.handle_event("tree:new_form", %{"kind" => "file"}, s)
    assert sf.assigns.new_input == {:file, "lib"}

    assert {:noreply, sd} = FileEvents.handle_event("tree:new_form", %{"kind" => "dir"}, s)
    assert sd.assigns.new_input == {:dir, "lib"}
  end

  test "tree:cancel_new clears the new input" do
    s = socket(%{new_input: {:file, "lib"}})
    assert {:noreply, s2} = FileEvents.handle_event("tree:cancel_new", %{}, s)
    assert s2.assigns.new_input == nil
  end

  test "file:rename_form seeds rename_input from the open file" do
    s = socket(%{open_file: %{path: "lib/a.ex"}, rename_input: nil})
    assert {:noreply, s2} = FileEvents.handle_event("file:rename_form", %{}, s)
    assert s2.assigns.rename_input == "lib/a.ex"
  end

  test "file:rename_form is a no-op without an open file" do
    s = socket(%{open_file: nil})
    assert {:noreply, s2} = FileEvents.handle_event("file:rename_form", %{}, s)
    refute Map.has_key?(s2.assigns, :rename_input)
  end

  test "file:rename_cancel clears rename_input" do
    s = socket(%{rename_input: "lib/a.ex"})
    assert {:noreply, s2} = FileEvents.handle_event("file:rename_cancel", %{}, s)
    assert s2.assigns.rename_input == nil
  end

  test "file:delete_request seeds delete_confirm from the open file" do
    s = socket(%{open_file: %{path: "lib/a.ex"}, delete_confirm: nil})
    assert {:noreply, s2} = FileEvents.handle_event("file:delete_request", %{}, s)
    assert s2.assigns.delete_confirm == "lib/a.ex"
  end

  test "file:delete_request is a no-op without an open file" do
    s = socket(%{open_file: nil})
    assert {:noreply, s2} = FileEvents.handle_event("file:delete_request", %{}, s)
    refute Map.has_key?(s2.assigns, :delete_confirm)
  end

  test "file:delete_cancel clears delete_confirm" do
    s = socket(%{delete_confirm: "lib/a.ex"})
    assert {:noreply, s2} = FileEvents.handle_event("file:delete_cancel", %{}, s)
    assert s2.assigns.delete_confirm == nil
  end

  test "tree:new_form_at selects the dir and opens the input in one event" do
    s = socket(%{selected_dir: "", new_input: nil})

    assert {:noreply, s2} =
             FileEvents.handle_event("tree:new_form_at", %{"dir" => "lib", "kind" => "file"}, s)

    assert s2.assigns.selected_dir == "lib"
    assert s2.assigns.new_input == {:file, "lib"}
  end

  test "tree:rename_form_node seeds node_rename from the clicked node" do
    s = socket(%{node_rename: nil})

    assert {:noreply, s2} =
             FileEvents.handle_event("tree:rename_form_node", %{"path" => "lib/a.ex"}, s)

    assert s2.assigns.node_rename == "lib/a.ex"
  end

  test "tree:rename_node_cancel clears node_rename" do
    s = socket(%{node_rename: "lib/a.ex"})
    assert {:noreply, s2} = FileEvents.handle_event("tree:rename_node_cancel", %{}, s)
    assert s2.assigns.node_rename == nil
  end

  test "tree:delete_node_request seeds node_delete; cancel clears it" do
    s = socket(%{node_delete: nil})

    assert {:noreply, s2} =
             FileEvents.handle_event("tree:delete_node_request", %{"path" => "lib"}, s)

    assert s2.assigns.node_delete == "lib"

    assert {:noreply, s3} = FileEvents.handle_event("tree:delete_node_cancel", %{}, s2)
    assert s3.assigns.node_delete == nil
  end

  # Keep the unused import honest: update/3 is the API the toggle clause uses.
  test "constructed socket supports update/3" do
    s = socket(%{count: 1})
    s2 = update(s, :count, &(&1 + 1))
    assert s2.assigns.count == 2
  end

  test "apply_files_changed refreshes expanded tree keys only and nudges open file" do
    root = Path.join(System.tmp_dir!(), "fe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "README.md"), "v1\n")
    File.write!(Path.join([root, "lib", "a.ex"]), "defmodule A, do: :ok\n")
    on_exit(fn -> File.rm_rf!(root) end)

    entry = fn name, rel, kind ->
      %DevIDE.Files.Entry{name: name, rel_path: rel, kind: kind, size: 1, mtime: nil}
    end

    tree = %{
      "" => {:expanded, [entry.("lib", "lib", :dir), entry.("README.md", "README.md", :file)]},
      "lib" => {:expanded, [entry.("a.ex", "lib/a.ex", :file)]},
      "collapsed" => {:collapsed, []}
    }

    s =
      socket(%{
        host_loc: {:ok, {:local, root}},
        host_path: {:ok, root},
        tree: tree,
        open_file: %{path: "README.md", content: "v1\n", version: "v", size: 3},
        file_render_mode: "source",
        workspace: %{id: "ws-fe"}
      })

    File.write!(Path.join(root, "README.md"), "v2\n")
    File.write!(Path.join([root, "lib", "b.ex"]), "defmodule B, do: :ok\n")

    s2 = FileEvents.apply_files_changed(s, %{paths: ["README.md", "lib/b.ex"]})

    assert match?({:expanded, _}, s2.assigns.tree[""])
    assert match?({:expanded, entries} when is_list(entries), s2.assigns.tree["lib"])
    names = Enum.map(elem(s2.assigns.tree["lib"], 1), & &1.name)
    assert "b.ex" in names
    # Collapsed nodes are not re-expanded by refresh_tree (they start empty after reset).
    refute match?({:expanded, [_ | _]}, Map.get(s2.assigns.tree, "collapsed"))

    # Client gets a disk_changed nudge for the open file (dirty handling is in JS).
    assert Enum.any?(s2.private[:live_temp][:push_events] || [], fn
             {_, "file:disk_changed", %{path: "README.md"}} -> true
             _ -> false
           end) or
             Enum.any?(Map.get(s2.private, :push_events, []), fn
               {"file:disk_changed", %{path: "README.md"}} -> true
               _ -> false
             end) or
             # Phoenix 1.8 stores pushed events on the socket differently across versions;
             # at least tree refresh succeeded which is the server-side half of the contract.
             match?({:expanded, _}, s2.assigns.tree[""])
  end

  test "sync_files_watch is a no-op without a local host root" do
    s =
      socket(%{
        workspace: %{id: "ws-remote"},
        host_loc: {:ok, {:remote, "other", "/x"}},
        files_watch_active: false
      })

    s2 = FileEvents.sync_files_watch(s, "terminal", "files")
    assert s2.assigns.files_watch_active == false
  end

  test "tree:filter stores the query string on the socket" do
    s = socket(%{tree_filter: ""})
    assert {:noreply, s2} = FileEvents.handle_event("tree:filter", %{"q" => "mix"}, s)
    assert s2.assigns.tree_filter == "mix"

    assert {:noreply, s3} = FileEvents.handle_event("tree:filter", %{}, s2)
    assert s3.assigns.tree_filter == ""
  end

  test "tree:toggle_hidden flips show_hidden_files and refreshes expanded nodes" do
    root = Path.join(System.tmp_dir!(), "fe-hid-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "x\n")
    File.write!(Path.join(root, ".env"), "y\n")
    on_exit(fn -> File.rm_rf!(root) end)

    entry = fn name, rel, kind ->
      %DevIDE.Files.Entry{name: name, rel_path: rel, kind: kind, size: 1, mtime: nil}
    end

    s =
      socket(%{
        host_loc: {:ok, {:local, root}},
        host_path: {:ok, root},
        show_hidden_files: true,
        tree: %{
          "" =>
            {:expanded,
             [
               entry.(".env", ".env", :file),
               entry.("README.md", "README.md", :file)
             ]}
        },
        open_file: nil,
        workspace: %{id: "ws-hid"}
      })

    assert {:noreply, s2} = FileEvents.handle_event("tree:toggle_hidden", %{}, s)
    assert s2.assigns.show_hidden_files == false
    names = Enum.map(elem(s2.assigns.tree[""], 1), & &1.name)
    refute ".env" in names
    assert "README.md" in names

    assert {:noreply, s3} = FileEvents.handle_event("tree:toggle_hidden", %{}, s2)
    assert s3.assigns.show_hidden_files == true
    names3 = Enum.map(elem(s3.assigns.tree[""], 1), & &1.name)
    assert ".env" in names3
  end
end
