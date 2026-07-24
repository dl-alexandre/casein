defmodule Casein.Workspaces.PreviewDeps do
  @moduledoc """
  Core-side impl of `Casein.Previews.Deps.Workspaces`.

  Thin pure delegation — no logic lives here. Preview resolves this module via
  `config :casein, :preview_deps`.
  """

  @behaviour Casein.Previews.Deps.Workspaces

  alias Casein.Workspaces
  alias Casein.Workspaces.Aliases

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
