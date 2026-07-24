defmodule Casein.Previews.Deps.Runtimes do
  @moduledoc """
  Preview-owned seam for runtime listing and runtime-owned preview servers.

  `Runtimes.PreviewLauncher` stays in the runtimes domain; only the call is
  inverted through this behaviour.
  """

  @type runtime :: map()

  @callback list_runtimes(filters :: map()) :: [runtime()]
  @callback runtime_preview_surfaces(runtime()) :: [map()]
  @callback runtime_preview_server(runtime()) :: map() | nil
  @callback ensure_preview_server_started(runtime()) :: :ok | {:error, term()}
end
