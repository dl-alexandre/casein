defmodule DevIDE.Git do
  @moduledoc """
  Git operations on a workspace. Behaviour-based so a remote/SSH adapter can
  slot in later without changing callers.
  """

  def branch(root), do: impl().branch(root)
  def status_short(root), do: impl().status_short(root)
  def diff(root, rel), do: impl().diff(root, rel)
  def diff_all(root), do: impl().diff_all(root)

  defp impl, do: Application.get_env(:dev_ide, :git_adapter, DevIDE.Git.LocalAdapter)
end
