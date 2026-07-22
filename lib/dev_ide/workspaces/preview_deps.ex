defmodule DevIDE.Workspaces.PreviewDeps do
  @moduledoc """
  Core-side impl of `DevIDE.Previews.Deps.Workspaces`.

  Thin pure delegation — no logic lives here. Preview resolves this module via
  `config :dev_ide, :preview_deps`.
  """

  @behaviour DevIDE.Previews.Deps.Workspaces

  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases

  @impl true
  def get(id), do: Workspaces.get(id)

  @impl true
  def attach_folder(path), do: Workspaces.attach_folder(path)

  @impl true
  def safe_host_path(workspace), do: Workspaces.safe_host_path(workspace)

  @impl true
  def safe_host_loc(workspace), do: Workspaces.safe_host_loc(workspace)

  @impl true
  def forward_auth_headers(workspace), do: Workspaces.forward_auth_headers(workspace)

  @impl true
  def viewer_ids(workspace_id), do: Aliases.viewer_ids(workspace_id)

  @impl true
  def viewer_ids(workspace_id, opts), do: Aliases.viewer_ids(workspace_id, opts)

  @impl true
  def linked?(left, right), do: Aliases.linked?(left, right)

  @impl true
  def viewer_route_id(workspace_id), do: Aliases.viewer_route_id(workspace_id)
end
