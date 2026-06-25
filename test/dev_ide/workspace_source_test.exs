defmodule DevIDE.WorkspaceSourceTest do
  use ExUnit.Case, async: false

  alias DevIDE.WorkspaceSource

  # ---------------------------------------------------------------------------
  # Test stub sources used to exercise the "impl exports the optional callback"
  # branches of WorkspaceSource. WorkspaceSource resolves the active source via
  # Application.get_env(:dev_ide, :workspace_source, ...) and then checks
  # function_exported?/3, so a module that defines a callback drives the
  # delegating branch and one that omits it drives the fallback branch.
  # ---------------------------------------------------------------------------

  # Exports every optional callback (both arities where applicable).
  defmodule FullSource do
    def prepare_local_argv(argv), do: ["wrap1" | argv]
    def prepare_local_argv(argv, opts), do: ["wrap2", "#{Keyword.get(opts, :tty, false)}" | argv]
    def local_tmux_pane_shell, do: "shell0"
    def local_tmux_pane_shell(host_cwd), do: "shell1:#{host_cwd}"
    def local_exec_cwd(host_cwd), do: "/mnt" <> host_cwd
    def default_log_service(_ws), do: "custom-svc"
    def create_form_fields, do: [:name, :type]
    def detect_capabilities(_ws, _root), do: [:cap_a, :cap_b]
  end

  # Exports only the arity-1 variants (no arity-0 / no arity-2).
  defmodule Arity1Source do
    def prepare_local_argv(argv), do: ["only1" | argv]
    def local_tmux_pane_shell(host_cwd), do: "only1:#{host_cwd}"
  end

  # Exports nothing optional — drives all fallback branches.
  defmodule EmptySource do
  end

  # default_log_service returns a non-binary, exercising the catch-all "app".
  defmodule BadLogSource do
    def default_log_service(_ws), do: :not_a_string
  end

  defp put_source(mod) do
    prev = Application.get_env(:dev_ide, :workspace_source)
    Application.put_env(:dev_ide, :workspace_source, mod)

    on_exit(fn ->
      if prev do
        Application.put_env(:dev_ide, :workspace_source, prev)
      else
        Application.delete_env(:dev_ide, :workspace_source)
      end
    end)
  end

  describe "impl/0" do
    test "defaults to Local when nothing configured" do
      prev = Application.get_env(:dev_ide, :workspace_source)
      Application.delete_env(:dev_ide, :workspace_source)

      on_exit(fn ->
        if prev, do: Application.put_env(:dev_ide, :workspace_source, prev)
      end)

      assert WorkspaceSource.impl() == DevIDE.WorkspaceSource.Local
    end

    test "returns the configured source module" do
      put_source(FullSource)
      assert WorkspaceSource.impl() == FullSource
    end
  end

  describe "prepare_local_argv/1 and /2" do
    test "delegates to arity-2 when source exports it" do
      put_source(FullSource)
      # /1 forwards to /2 with [] opts -> tty default false
      assert WorkspaceSource.prepare_local_argv(["a", "b"]) == ["wrap2", "false", "a", "b"]
      assert WorkspaceSource.prepare_local_argv(["a"], tty: true) == ["wrap2", "true", "a"]
    end

    test "falls back to arity-1 when only arity-1 is exported" do
      put_source(Arity1Source)
      assert WorkspaceSource.prepare_local_argv(["x"], tty: true) == ["only1", "x"]
      assert WorkspaceSource.prepare_local_argv(["x"]) == ["only1", "x"]
    end

    test "returns argv unchanged when source exports neither" do
      put_source(EmptySource)
      assert WorkspaceSource.prepare_local_argv(["echo", "hi"]) == ["echo", "hi"]
      assert WorkspaceSource.prepare_local_argv(["echo"], tty: false) == ["echo"]
    end

    test "default Local source is identity (exports neither arity)" do
      put_source(DevIDE.WorkspaceSource.Local)
      assert WorkspaceSource.prepare_local_argv(["ls", "-la"]) == ["ls", "-la"]
    end
  end

  describe "local_tmux_pane_shell/0" do
    test "delegates when source exports arity-0" do
      put_source(FullSource)
      assert WorkspaceSource.local_tmux_pane_shell() == "shell0"
    end

    test "returns nil when source does not export arity-0" do
      put_source(Arity1Source)
      assert WorkspaceSource.local_tmux_pane_shell() == nil
    end

    test "returns nil for empty source" do
      put_source(EmptySource)
      assert WorkspaceSource.local_tmux_pane_shell() == nil
    end
  end

  describe "local_tmux_pane_shell/1" do
    test "delegates to arity-1 when exported" do
      put_source(FullSource)
      assert WorkspaceSource.local_tmux_pane_shell("/ws/foo") == "shell1:/ws/foo"
    end

    test "uses only the arity-1 variant when that is what is exported" do
      put_source(Arity1Source)
      assert WorkspaceSource.local_tmux_pane_shell("/ws/bar") == "only1:/ws/bar"
    end

    test "falls back to arity-0 when only arity-0 is exported" do
      # FullSource exports both; verify arity-1 wins. A dedicated arity-0-only
      # module proves the second cond arm.
      defmodule Arity0OnlyShell do
        def local_tmux_pane_shell, do: "from0"
      end

      put_source(Arity0OnlyShell)
      assert WorkspaceSource.local_tmux_pane_shell("/ws/baz") == "from0"
    end

    test "returns nil when neither arity exported" do
      put_source(EmptySource)
      assert WorkspaceSource.local_tmux_pane_shell("/ws/none") == nil
    end
  end

  describe "local_exec_cwd/1" do
    test "delegates when source exports it" do
      put_source(FullSource)
      assert WorkspaceSource.local_exec_cwd("/ws/x") == "/mnt/ws/x"
    end

    test "returns host_cwd unchanged when not exported" do
      put_source(EmptySource)
      assert WorkspaceSource.local_exec_cwd("/ws/x") == "/ws/x"
    end

    test "default Local source returns cwd unchanged" do
      put_source(DevIDE.WorkspaceSource.Local)
      assert WorkspaceSource.local_exec_cwd("/some/path") == "/some/path"
    end
  end

  describe "default_log_service/1" do
    test "delegates and returns a binary service name" do
      put_source(FullSource)
      assert WorkspaceSource.default_log_service(%{}) == "custom-svc"
    end

    test "returns \"app\" when delegate returns a non-binary" do
      put_source(BadLogSource)
      assert WorkspaceSource.default_log_service(%{}) == "app"
    end

    test "returns \"app\" when source does not export it" do
      put_source(EmptySource)
      assert WorkspaceSource.default_log_service(%{}) == "app"
    end

    test "default Local source returns \"app\"" do
      put_source(DevIDE.WorkspaceSource.Local)
      assert WorkspaceSource.default_log_service(%DevIDE.Workspace{id: "w", name: "w"}) == "app"
    end
  end

  describe "detect_capabilities/2" do
    test "delegates when source exports detect_capabilities/2" do
      put_source(FullSource)
      assert WorkspaceSource.detect_capabilities(%{}, "/root") == [:cap_a, :cap_b]
    end

    test "falls back to filesystem-only detection when not exported" do
      put_source(EmptySource)
      # LocalAdapter.detect_filesystem_only on a nil root yields a list.
      caps = WorkspaceSource.detect_capabilities(%{}, nil)
      assert is_list(caps)
    end
  end

  describe "create_form_fields/0" do
    test "delegates when source exports it" do
      put_source(FullSource)
      assert WorkspaceSource.create_form_fields() == [:name, :type]
    end

    test "returns [:name] when source does not export it" do
      put_source(EmptySource)
      assert WorkspaceSource.create_form_fields() == [:name]
    end

    test "default Local source returns [:name]" do
      put_source(DevIDE.WorkspaceSource.Local)
      assert WorkspaceSource.create_form_fields() == [:name]
    end
  end
end
