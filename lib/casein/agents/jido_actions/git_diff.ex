defmodule Casein.Agents.JidoActions.GitDiff do
  @moduledoc "Typed, scope-limited Git diff for a Jido Workcell."

  use Jido.Action,
    name: "git_diff",
    description: "Bounded unified diff for the assigned attempt worktree.",
    category: "git",
    tags: ["git"],
    vsn: "1.0.0",
    schema: [paths: [type: {:list, :string}, required: true]]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.git_diff(params, ctx)
end
