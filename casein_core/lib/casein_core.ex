defmodule CaseinCore do
  @moduledoc """
  Generic BEAM primitives for code-aware developer tooling.

  Three dependency-free leaf libraries, each its own `Boundary`:

    * `ExecCtl` — OS process spawning + output streaming over erlexec.
    * `GitCtl`  — git worktree/branch inspection (shells out to the `git` binary).
    * `McpCtl`  — helpers for building MCP tool-definition maps.

  This module is a thin documentation/convenience facade. The libraries
  carry no dependency on each other and may be used directly.

  ## Host-injected policy

  `GitCtl` accepts an optional agent-inference hook so host applications can
  label checkouts without `GitCtl` knowing host conventions:

      config :git_ctl, agent_inference: {MyApp.Agents, :infer}

  ## Vocabulary scrub (pre-1.0)

  `McpCtl.Schema` and `McpCtl.Params` currently encode Casein-specific
  vocabulary (workspace ids, folder attachment, tmux/preview wording) in
  their runtime description strings. They compile and work standalone, but
  are slated to become host-configurable before a generic 1.0. `McpCtl.Tool`
  and `McpCtl.Error` are already generic.
  """

  use Boundary, deps: [ExecCtl, GitCtl, McpCtl], exports: :all

  @doc "See `GitCtl.Inspector.inspect_cwd/1`."
  defdelegate git_inspect(cwd), to: GitCtl.Inspector, as: :inspect_cwd

  @doc "See `ExecCtl.Port.run/3`."
  defdelegate exec_run(argv, opts, subscriber), to: ExecCtl.Port, as: :run

  @doc "See `McpCtl.Tool.define/3`."
  defdelegate mcp_tool(name, description, parameters), to: McpCtl.Tool, as: :define
end
