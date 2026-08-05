defmodule Casein.Previews.Deps.Runtimes do
  @moduledoc """
  Preview-owned seam for runtime listing and runtime-owned preview servers.

  `Runtimes.PreviewLauncher` stays in the runtimes domain; only the call is
  inverted through this behaviour.
  """

  @type runtime :: map()

  @callback list_runtimes(filters :: map()) :: [runtime()]

  @doc """
  Agent worktrees belonging to one workspace, each carrying its `:path`.

  Scoped to a single workspace on purpose. Agent worktree *roots* are global
  (`/data/casein-agent-worktrees`, …), so anything keyed off a root would let one
  workspace claim a peer's dev-server ports; this is the per-workspace
  attribution that keeps `SocketDetector` from doing that.
  """
  @callback list_agent_worktrees(workspace_id :: String.t()) :: [map()]
  @callback runtime_preview_surfaces(runtime()) :: [map()]
  @callback runtime_preview_server(runtime()) :: map() | nil
  @callback ensure_preview_server_started(runtime()) :: :ok | {:error, term()}
end
