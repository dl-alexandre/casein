defmodule DevIDE do
  @moduledoc """
  Boundary root for the DevIDE domain contexts (`DevIDE.*`): terminals,
  audit, workspaces, policy, agents, preview, and friends.

  The domain layer may depend on the repo (`DevIDE.Repo`, its own
  boundary) but never on the web layer (`DevIdeWeb`) or application
  infrastructure. The `boundary` compiler enforces this at build time;
  violations surface as compile warnings, which `mix precommit` promotes
  to errors.

  Infrastructure roots such as `DevIDE.Application` and `DevIDE.Repo` declare
  their own top-level boundaries. Do not introduce a case-only `DevIde` root:
  its BEAM filename overwrites this module on case-insensitive filesystems.
  """

  use Boundary,
    deps: [
      DevIDE.Repo,
      DevIDE.Files.PathSafety,
      TmuxCtl,
      PreviewCtl,
      TerminalCtl,
      GitCtl,
      ExecCtl,
      McpCtl
    ],
    exports: :all
end
