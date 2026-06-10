defmodule DevIde do
  @moduledoc """
  Boundary root for app infrastructure (`DevIde.*`): the OTP application,
  Repo, Mailer, and release tasks.

  `DevIde.Application` supervises both domain processes (`DevIDE.*`) and
  the web endpoint (`DevIdeWeb.*`), so this boundary may depend on both.
  The domain itself lives under `DevIDE` (see `lib/dev_ide_domain.ex`).
  """

  use Boundary,
    deps: [DevIDE, DevIdeWeb, DevIde.Repo],
    exports: :all
end
