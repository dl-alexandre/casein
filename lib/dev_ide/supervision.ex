defmodule DevIDE.Supervision do
  @moduledoc """
  Boundary for the app's supervision subtrees (`DevIDE.Supervision.*`).

  These modules group the application's child specs (terminals, agents,
  commands, previews, state stores, platform services, deployment) into
  focused supervisors started by `DevIDE.Application`. They name domain
  (`DevIDE.*`), web (`DevIdeWeb.*`), and preview-control (`PreviewCtl.*`)
  processes in their child lists, so this boundary may depend on those.

  A nested boundary under `DevIde`, mirroring the sibling app-infrastructure
  boundaries (`DevIDE.Application`, `DevIDE.Repo`, …).
  """

  use Boundary,
    top_level?: true,
    deps: [DevIDE, DevIdeWeb, PreviewCtl],
    exports: []
end
