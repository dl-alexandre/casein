defmodule DevIDE.Git do
  @moduledoc """
  Git operations on a workspace. Behaviour-based so a remote/SSH adapter can
  slot in later without changing callers.
  """

  @type status_entry :: %{x: String.t(), y: String.t(), path: String.t()}

  @callback status_short(root :: String.t()) :: {:ok, [status_entry()]} | {:error, term()}
  @callback diff(root :: String.t(), rel :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback diff_all(root :: String.t()) :: {:ok, String.t()} | {:error, term()}

  def status_short(root), do: impl().status_short(root)
  def diff(root, rel), do: impl().diff(root, rel)
  def diff_all(root), do: impl().diff_all(root)

  defp impl, do: Application.get_env(:dev_ide, :git_adapter, DevIDE.Git.LocalAdapter)
end
