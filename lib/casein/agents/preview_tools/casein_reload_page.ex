defmodule Casein.Agents.PreviewTools.CaseinReloadPage do
  @moduledoc "casein_reload_page."

  use Jido.Action,
    name: "casein_reload_page",
    description: "Ask connected Casein viewers to reload the whole workspace page.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      actor_id: [type: :string],
      reason: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          actor_id: Params.actor_id(),
          reason: Helpers.reload_reason_param()
        }),
        [:workspace_id]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("casein_reload_page")

  @impl Jido.Action
  def run(params, context) do
    workspace = Map.get(context, :workspace, %{})
    Impl.reload_page(workspace, Helpers.to_impl_args(params))
  end
end
