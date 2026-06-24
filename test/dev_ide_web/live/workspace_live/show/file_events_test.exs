defmodule DevIdeWeb.WorkspaceLive.Show.FileEventsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [assign: 3, update: 3]

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

  # Keep the unused import honest: update/3 is the API the toggle clause uses.
  test "constructed socket supports update/3" do
    s = socket(%{count: 1})
    s2 = update(s, :count, &(&1 + 1))
    assert s2.assigns.count == 2
  end
end
