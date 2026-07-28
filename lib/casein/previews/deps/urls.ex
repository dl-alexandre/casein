defmodule Casein.Previews.Deps.Urls do
  @moduledoc """
  Preview-owned seam for credential-bearing Casein API URL selection.

  Preview modules resolve the core implementation at runtime so URL
  canonicalization cannot re-entangle the preview and core dependency graph.
  The implementation is verified by contract tests instead of declaring this
  behaviour from core, which would itself create a reverse compile-time edge.
  """

  @callback base_url() :: String.t()
  @callback api_base_url() :: String.t()
  @callback preview_url() :: String.t()
end
