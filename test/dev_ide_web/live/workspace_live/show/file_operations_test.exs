defmodule DevIdeWeb.WorkspaceLive.Show.FileOperationsTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.FileOperations

  # Mirror file_events_test.exs: bare socket with __changed__ for assign/3.
  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  defp scratch_dir! do
    tmp = Path.join(System.tmp_dir!(), "fileops_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  describe "do_create/3 confinement" do
    test "creates a file under root" do
      tmp = scratch_dir!()

      assert :ok = FileOperations.do_create(:file, tmp, "safe.txt")
      assert File.exists?(Path.join(tmp, "safe.txt"))
    end

    test "refuses path escape and does not create outside root" do
      tmp = scratch_dir!()
      escaped = Path.expand("../escape.txt", tmp)
      # Clear ambient pollution under /tmp so the post-condition is falsifiable.
      if File.exists?(escaped), do: File.rm_rf!(escaped)
      on_exit(fn -> File.rm_rf!(escaped) end)

      assert {:error, :outside_root} = FileOperations.do_create(:file, tmp, "../escape.txt")
      refute File.exists?(escaped)
    end

    test "creates a directory under root" do
      tmp = scratch_dir!()

      assert :ok = FileOperations.do_create(:dir, tmp, "sub")
      assert File.dir?(Path.join(tmp, "sub"))
    end
  end

  describe "root_tree/4" do
    test "lists local host root into the empty-path expanded node" do
      tmp = scratch_dir!()
      File.write!(Path.join(tmp, "a.ex"), "x")

      tree = FileOperations.root_tree(%{}, :error, {:ok, tmp})

      assert %{"" => {:expanded, entries}} = tree
      assert Enum.any?(entries, fn %DevIDE.Files.Entry{name: name} -> name == "a.ex" end)
    end

    test "pass-through when host_loc and host_path are not ok" do
      assert FileOperations.root_tree(%{keep: 1}, :error, :error) == %{keep: 1}
    end
  end

  describe "assign_open_file/2" do
    test "clears open file and symbols when file is nil" do
      s = FileOperations.assign_open_file(socket(%{}), nil)

      assert s.assigns.open_file == nil
      assert s.assigns.file_symbols == []
    end

    test "sets open file and empty symbols for a plain .txt map" do
      file = %{path: "notes.txt", content: "hello"}
      s = FileOperations.assign_open_file(socket(%{}), file)

      assert s.assigns.open_file == file
      assert s.assigns.file_symbols == []
    end
  end

  describe "git_status/1" do
    test "fallback returns empty list for non-ok loc" do
      assert FileOperations.git_status(:error) == []
    end
  end
end
