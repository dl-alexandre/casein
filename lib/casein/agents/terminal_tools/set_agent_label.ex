defmodule Casein.Agents.TerminalTools.SetAgentLabel do
  @moduledoc "terminal_set_agent_label."

  use Jido.Action,
    name: "terminal_set_agent_label",
    description:
      "Set a short conversation label for a pane in Casein chrome (does not rename tmux windows). Defaults to the dedicated agent pane when pane is omitted. Pass freeze: true to keep the label until the pane closes.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      pane: [type: :string],
      label: [type: :string, required: true],
      freeze: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          caller_pane: Helpers.caller_pane_param(),
          pane: Helpers.pane_param(),
          label: Helpers.label_param(),
          freeze: Helpers.freeze_param()
        }),
        ["workspace_id", "label"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_set_agent_label")

  @impl Jido.Action
  def run(params, _context) do
    Impl.set_agent_label(Helpers.to_impl_args(params))
  end
end
