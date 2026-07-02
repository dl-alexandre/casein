defmodule DevIDE.Test.WrappingWorkspaceSourceTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.WorkspaceSource
  alias DevIDE.Test.WrappingWorkspaceSource

  setup do
    prev = Application.get_env(:dev_ide, :workspace_source)
    Application.put_env(:dev_ide, :workspace_source, WrappingWorkspaceSource)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, :workspace_source, prev),
        else: Application.delete_env(:dev_ide, :workspace_source)
    end)

    :ok
  end

  test "prepare_local_argv/1 wraps argv via the test source" do
    assert WorkspaceSource.prepare_local_argv(["tmux", "list-sessions"]) ==
             ["sh", "-c", "printf wrapped >&2; exit 42"]
  end

  test "prepare_local_argv/2 delegates to the two-arity callback" do
    assert WorkspaceSource.prepare_local_argv(["mix", "test"], cwd: "/tmp") ==
             ["sh", "-c", "printf wrapped >&2; exit 42"]
  end

  test "direct module callbacks match the facade" do
    assert WrappingWorkspaceSource.prepare_local_argv(["echo"]) ==
             ["sh", "-c", "printf wrapped >&2; exit 42"]

    assert WrappingWorkspaceSource.prepare_local_argv(["echo"], tty: true) ==
             ["sh", "-c", "printf wrapped >&2; exit 42"]
  end
end
