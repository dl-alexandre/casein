defmodule DevIde.Supervision do
  @moduledoc """
  Boundary for the app's supervision subtrees (`DevIde.Supervision.*`).

  These modules group the application's child specs (terminals, agents,
  commands, previews, state stores, platform services, deployment) into
  focused supervisors started by `DevIde.Application`. They name domain
  (`DevIDE.*`), web (`DevIdeWeb.*`), and preview-control (`PreviewCtl.*`)
  processes in their child lists, so this boundary may depend on those.

  A nested boundary under `DevIde`, mirroring the sibling app-infrastructure
  boundaries (`DevIde.Application`, `DevIde.Repo`, …).
  """

  use Boundary, deps: [DevIDE, DevIdeWeb, PreviewCtl], exports: []
end
