defmodule DevIDE.TmpWorkspace do
  @moduledoc """
  Test helper: mint a uniquely-named temp directory under `System.tmp_dir!/0`
  and register an `on_exit` callback that removes it after the test.

  Historically ~a dozen test files copy-pasted a private `seed_workspace!` that
  did `Path.join(System.tmp_dir!(), "<prefix>-...")` + `File.mkdir_p!` but never
  cleaned it up, leaking tens of thousands of workspace dirs into `/tmp` on the
  devbox. Route those mints through `root!/1` so cleanup is automatic and uniform
  (mirrors the correct pattern already in `DevIDE.GitRepoCase`).

  Use inside a `setup` block (or any function invoked from one, so `on_exit`
  registers against the running test process):

      setup do
        root = DevIDE.TmpWorkspace.root!("preview-panes")
        # ... seed under `root`; it is removed automatically after the test
      end
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Returns a fresh, created temp directory prefixed with `prefix`, and schedules
  its recursive removal after the current test.
  """
  @spec root!(String.t()) :: String.t()
  def root!(prefix) when is_binary(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
