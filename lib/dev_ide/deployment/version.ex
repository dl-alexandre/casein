defmodule DevIDE.Deployment.Version do
  @moduledoc """
  The running release's git revision.

  Extracted from `DevIDE.Deployment.Registry` so `Drift` can read the current
  version without depending on `Registry` (which calls `Drift.check_async/0` —
  the two formed a compile-time cycle). This is pure: it reads an env var / the
  app vsn and holds no process state.
  """

  @spec version() :: String.t()
  def version do
    System.get_env("DEVIDE_GIT_REVISION") ||
      to_string(Application.spec(:dev_ide, :vsn))
  rescue
    _ -> "dev"
  end
end
