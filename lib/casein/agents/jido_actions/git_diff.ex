defmodule Casein.Agents.JidoActions.GitDiff do
  @moduledoc "Typed `git_diff` — not yet on the Code MCP contract."

  use Jido.Action,
    name: "git_diff",
    description: "Bounded unified diff for the assigned attempt worktree.",
    category: "git",
    tags: ["git"],
    vsn: "1.0.0",
    schema: []

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(_params, ctx), do: Runner.unsupported("git_diff", ctx)
end
