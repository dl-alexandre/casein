defmodule DevIDE.WorkspaceSource.LocalTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.WorkspaceSource.Local
  alias DevIDE.Workspace

  setup do
    # Save and restore global config
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_roots = Application.get_env(:dev_ide, :workspaces_roots)

    # Create a unique temporary root for this test
    root = Path.join(System.tmp_dir!(), "devide_local_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(:dev_ide, :workspaces_root, root)
    Application.put_env(:dev_ide, :workspaces_roots, [])

    on_exit(fn ->
      Application.put_env(:dev_ide, :workspaces_root, prev_root)
      Application.put_env(:dev_ide, :workspaces_roots, prev_roots)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  describe "list/2" do
    test "returns workspaces for subdirectories", %{root: root} do
      File.mkdir_p!(Path.join(root, "alpha"))
      File.mkdir_p!(Path.join(root, "beta"))

      {:ok, list} = Local.list()

      ids = Enum.map(list, & &1.id) |> Enum.sort()
      assert ids == ["alpha", "beta"]
    end

    test "ignores files and only returns directories", %{root: root} do
      File.mkdir_p!(Path.join(root, "real-ws"))
      File.write!(Path.join(root, "not-a-ws"), "hello")

      {:ok, list} = Local.list()
      assert Enum.map(list, & &1.id) == ["real-ws"]
    end

    test "returns empty list when root does not exist" do
      Application.put_env(:dev_ide, :workspaces_root, "/this/path/does/not/exist")

      {:ok, list} = Local.list()
      assert list == []
    end

    test "populates branch when git repo is present", %{root: root} do
      ws_path = Path.join(root, "with-git")
      File.mkdir_p!(ws_path)
      System.cmd("git", ["init", "-b", "main"], cd: ws_path, stderr_to_stdout: true)

      {:ok, [ws]} = Local.list()
      assert ws.branch == "main"
    end
  end

  describe "get/2" do
    test "returns workspace when directory exists", %{root: root} do
      File.mkdir_p!(Path.join(root, "my-project"))

      {:ok, ws} = Local.get("my-project")
      assert ws.id == "my-project"
      assert ws.path == Path.join(root, "my-project")
    end

    test "returns error when directory does not exist" do
      assert Local.get("does-not-exist") == {:error, :not_found}
    end
  end

  describe "create/2" do
    test "creates a new workspace directory", %{root: root} do
      assert {:ok, ws} = Local.create(%{name: "new-one"}, nil)
      assert ws.id == "new-one"
      assert File.dir?(Path.join(root, "new-one"))
    end

    test "rejects invalid names" do
      assert {:error, :invalid_name} = Local.create(%{name: ""}, nil)
      assert {:error, :invalid_name} = Local.create(%{name: "../evil"}, nil)
      assert {:error, :invalid_name} = Local.create(%{name: "has/slash"}, nil)
    end

    test "rejects creation when workspace already exists", %{root: root} do
      File.mkdir_p!(Path.join(root, "exists"))
      assert {:error, :already_exists} = Local.create(%{name: "exists"}, nil)
    end

    test "accepts string-keyed params" do
      assert {:ok, _} = Local.create(%{"name" => "string-key"}, nil)
    end
  end

  describe "delete/3" do
    test "refuses deletion without :allow_destructive", %{root: root} do
      File.mkdir_p!(Path.join(root, "to-delete"))
      assert {:error, :destructive_not_allowed} = Local.delete("to-delete")
    end

    test "deletes when :allow_destructive is true", %{root: root} do
      path = Path.join(root, "deletable")
      File.mkdir_p!(path)
      assert {:ok, :deleted} = Local.delete("deletable", allow_destructive: true)
      refute File.exists?(path)
    end

    test "returns not_found for missing directory" do
      assert {:error, :not_found} = Local.delete("nope", allow_destructive: true)
    end
  end

  describe "safe_host_path/1 and safe_host_loc/1" do
    test "accepts paths under the configured root", %{root: root} do
      File.mkdir_p!(Path.join(root, "safe-ws"))

      ws = %Workspace{id: "safe-ws", path: Path.join(root, "safe-ws")}
      assert {:ok, _} = Local.safe_host_path(ws)
      assert {:ok, {:local, _}} = Local.safe_host_loc(ws)
    end

    test "rejects paths outside the root" do
      ws = %Workspace{id: "evil", path: "/etc/passwd"}
      assert {:error, :outside_root} = Local.safe_host_path(ws)
    end
  end

  describe "stream_logs/3 and default_log_service/1" do
    test "stream_logs returns not_supported" do
      assert Local.stream_logs("any", "app", self()) == {:error, :not_supported}
    end

    test "default_log_service always returns app" do
      assert Local.default_log_service(%{}) == "app"
    end
  end
end
