defmodule Casein.Runtimes.PreviewDeps do
  @moduledoc """
  Core-side impl of `Casein.Previews.Deps.Runtimes`.

  Thin pure delegation to `Casein.Runtimes` / `Casein.Runtimes.PreviewLauncher`.
  """

  @behaviour Casein.Previews.Deps.Runtimes

  alias Casein.Runtimes
  alias Casein.Runtimes.PreviewLauncher

  @impl true
  def list_runtimes(filters), do: Runtimes.list_runtimes(filters)

  @impl true
  def list_agent_worktrees(workspace_id), do: Runtimes.list_agent_worktrees(workspace_id)

  @impl true
  def runtime_preview_surfaces(runtime), do: Runtimes.runtime_preview_surfaces(runtime)

  @impl true
  def runtime_preview_server(runtime), do: Runtimes.runtime_preview_server(runtime)

  @impl true
  def ensure_preview_server_started(runtime), do: PreviewLauncher.ensure_started(runtime)
end
