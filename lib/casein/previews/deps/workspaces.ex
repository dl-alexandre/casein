defmodule Casein.Previews.Deps.Workspaces do
  @moduledoc """
  Preview-owned seam for workspace lookup, path safety, and viewer aliases.

  Merges former direct calls to `Casein.Workspaces` and
  `Casein.Workspaces.Aliases` into one injectable behaviour.
  """

  @type workspace :: map()
  @type workspace_loc :: {:local, String.t()} | {:remote, String.t(), String.t()}

  @callback get(id :: String.t()) :: {:ok, workspace()} | {:error, term()}
  @callback attach_folder(path :: String.t()) :: {:ok, workspace()} | {:error, atom()}
  @callback safe_host_path(workspace()) :: {:ok, String.t()} | {:error, atom()}
  @callback safe_host_loc(workspace()) :: {:ok, workspace_loc()} | {:error, atom()}
  @callback forward_auth_headers(workspace()) :: %{String.t() => String.t()} | nil
  @callback viewer_ids(workspace_id :: String.t(), opts :: keyword()) :: [String.t()]
  @callback linked?(left :: String.t(), right :: String.t()) :: boolean()
  @callback viewer_route_id(workspace_id :: String.t()) :: String.t()
end
