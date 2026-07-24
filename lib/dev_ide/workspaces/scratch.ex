defmodule Casein.Workspaces.Scratch do
  @moduledoc """
  Synthetic workspaceless "scratch" terminal.

  Scratch is a real `%Casein.Workspace{}` with sentinel id/name `"__scratch__"`
  so the cockpit's ~250 unguarded `workspace.id` / `workspace.name` derefs keep
  working. The PTY is rooted at the configured home path (`:home_workspace_path`
  or `$HOME`) rather than a managed workspace checkout.

  Do not thread `nil` workspace through LiveViews — use this module instead.
  """

  alias Casein.Workspace

  @id "__scratch__"

  @doc "Sentinel id (and name) for the scratch workspace."
  @spec id() :: String.t()
  def id, do: @id

  @doc """
  True when the value is the scratch sentinel id or a scratch workspace struct.
  """
  @spec scratch?(term()) :: boolean()
  def scratch?(@id), do: true
  def scratch?(%Workspace{id: @id}), do: true
  def scratch?(%Workspace{metadata: %{scratch: true}}), do: true
  def scratch?(_), do: false

  @doc """
  Absolute filesystem root for the scratch PTY.

  Prefers `:casein, :home_workspace_path` when set; otherwise the process
  user's home directory.
  """
  @spec home_path() :: String.t()
  def home_path do
    case Application.get_env(:casein, :home_workspace_path) do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        System.get_env("HOME") || System.user_home!()
    end
  end

  @doc "Synthetic `%Workspace{}` for the workspaceless scratch terminal."
  @spec workspace() :: Workspace.t()
  def workspace do
    home = home_path()

    %Workspace{
      id: @id,
      name: @id,
      user: nil,
      branch: nil,
      status: :running,
      path: home,
      metadata: %{scratch: true}
    }
  end
end
