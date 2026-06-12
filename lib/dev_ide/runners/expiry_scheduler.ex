defmodule DevIDE.Runners.ExpiryScheduler do
  @moduledoc """
  Compatibility shim — lease expiry ticks now run via `ExpireLeasesWorker` (Oban).

  `interval_ms/0` remains the configuration entry point for tests and docs.
  """

  @doc "Returns the configured tick interval in milliseconds."
  defdelegate interval_ms(), to: DevIDE.Runners.ExpireLeasesWorker
end
