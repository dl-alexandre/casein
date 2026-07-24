defmodule Casein.Previews.Deps do
  @moduledoc """
  Runtime resolution of preview-domain outbound dependencies.

  Preview modules never name core modules at compile time. Instead they call
  `impl/1`, which reads `config :casein, :preview_deps` (set in
  `config/config.exs`). A compile-time module default here would re-create the
  xref edge this seam exists to remove.
  """

  @type key :: :workspaces | :terminals | :runtimes | :pane_sink

  @doc "Resolve the configured impl module for a preview dependency seam."
  @spec impl(key()) :: module()
  def impl(key) when key in [:workspaces, :terminals, :runtimes, :pane_sink] do
    :casein
    |> Application.fetch_env!(:preview_deps)
    |> Keyword.fetch!(key)
  end

  # The atom the terminals topology seam tags its PubSub broadcasts with.
  # Written as a raw atom (NOT the `Casein.Terminals.TmuxTopology` module
  # reference) on purpose: preview GenServers pattern-match `{tag, payload}` in
  # their `handle_info` heads, and a real module reference there would recreate
  # the preview -> core Terminals xref edge this whole seam exists to remove.
  # Centralizing it here keeps the deliberate coupling documented in one place
  # instead of scattered as an opaque literal across preview modules.
  @topology_message_tag :"Elixir.Casein.Terminals.TmuxTopology"

  @doc """
  Message-envelope tag for terminal topology broadcasts arriving via the
  `Deps.Terminals.topology_subscribe/1` seam. Use as a compile-time constant:
  `@topology_tag Casein.Previews.Deps.topology_tag()`.
  """
  @spec topology_tag() :: atom()
  def topology_tag, do: @topology_message_tag
end
