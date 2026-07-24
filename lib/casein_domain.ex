defmodule Casein do
  @moduledoc """
  Boundary root for the Casein domain contexts (`Casein.*`): terminals,
  audit, workspaces, policy, agents, preview, and friends.

  The domain layer may depend on the repo (`Casein.Repo`, its own
  boundary) but never on the web layer (`CaseinWeb`) or application
  infrastructure. The `boundary` compiler enforces this at build time;
  violations surface as compile warnings, which `mix precommit` promotes
  to errors.

  Infrastructure roots such as `Casein.Application` and `Casein.Repo` declare
  their own top-level boundaries. Do not introduce a case-only `Casein` root:
  its BEAM filename overwrites this module on case-insensitive filesystems.
  """

  use Boundary,
    deps: [
      Casein.Repo,
      Casein.Files.PathSafety,
      TmuxCtl,
      PreviewCtl,
      TerminalCtl,
      GitCtl,
      ExecCtl,
      McpCtl
    ],
    exports: :all
end
