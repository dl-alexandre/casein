defmodule Casein.Git do
  @moduledoc """
  Git operations on a workspace. Behaviour-based so a remote/SSH adapter can
  slot in later without changing callers.
  """

  def branch(root), do: impl().branch(root)
  def status_short(root), do: impl().status_short(root)
  def diff(root, rel), do: impl().diff(root, rel)
  def diff_all(root), do: impl().diff_all(root)

  # Resolved through Casein.ProcessEnv so a test can swap the adapter for its
  # own process (and run async: true) instead of mutating global Application env.
  defp impl, do: Casein.ProcessEnv.get(:casein, :git_adapter, Casein.Git.LocalAdapter)
end
