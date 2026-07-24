defmodule Casein.Supervision do
  @moduledoc """
  Boundary for the app's supervision subtrees (`Casein.Supervision.*`).

  These modules group the application's child specs (terminals, agents,
  commands, previews, state stores, platform services, deployment) into
  focused supervisors started by `Casein.Application`. They name domain
  (`Casein.*`), web (`CaseinWeb.*`), and preview-control (`PreviewCtl.*`)
  processes in their child lists, so this boundary may depend on those.

  An explicit application-infrastructure boundary, mirroring the sibling
  boundaries (`Casein.Application`, `Casein.Repo`, …).
  """

  use Boundary,
    top_level?: true,
    deps: [Casein, CaseinWeb, PreviewCtl],
    exports: []
end
