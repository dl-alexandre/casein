defmodule Casein.Agents.JidoActions.GitStatus do
  @moduledoc "Typed, scope-limited Git status for a Jido Workcell."

  use Jido.Action,
    name: "git_status",
    description: "Structured git status for the assigned attempt worktree.",
    category: "git",
    tags: ["git"],
    vsn: "1.0.0",
    schema: []

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(_params, ctx), do: Runner.git_status(ctx)
end
