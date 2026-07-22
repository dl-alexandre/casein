defmodule DevIDE.Previews.Deps do
  @moduledoc """
  Runtime resolution of preview-domain outbound dependencies.

  Preview modules never name core modules at compile time. Instead they call
  `impl/1`, which reads `config :dev_ide, :preview_deps` (set in
  `config/config.exs`). A compile-time module default here would re-create the
  xref edge this seam exists to remove.
  """

  @type key :: :workspaces | :terminals | :runtimes | :pane_sink

  @doc "Resolve the configured impl module for a preview dependency seam."
  @spec impl(key()) :: module()
  def impl(key) when key in [:workspaces, :terminals, :runtimes, :pane_sink] do
    :dev_ide
    |> Application.fetch_env!(:preview_deps)
    |> Keyword.fetch!(key)
  end
end
