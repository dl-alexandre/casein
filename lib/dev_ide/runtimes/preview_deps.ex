defmodule DevIDE.Runtimes.PreviewDeps do
  @moduledoc """
  Core-side impl of `DevIDE.Previews.Deps.Runtimes`.

  Thin pure delegation to `DevIDE.Runtimes` / `DevIDE.Runtimes.PreviewLauncher`.
  """

  @behaviour DevIDE.Previews.Deps.Runtimes

  alias DevIDE.Runtimes
  alias DevIDE.Runtimes.PreviewLauncher

  @impl true
  def list_runtimes(filters), do: Runtimes.list_runtimes(filters)

  @impl true
  def runtime_preview_surfaces(runtime), do: Runtimes.runtime_preview_surfaces(runtime)

  @impl true
  def runtime_preview_server(runtime), do: Runtimes.runtime_preview_server(runtime)

  @impl true
  def ensure_preview_server_started(runtime), do: PreviewLauncher.ensure_started(runtime)
end
