defmodule Casein.Agents.TerminalTools.LayoutApply do
  @moduledoc "terminal_layout_apply — converge a session onto a saved layout template."

  use Jido.Action,
    name: "terminal_layout_apply",
    description:
      "Converge a workspace tmux session onto a saved layout template (declarative). " <>
        "Plans by default: call it once to get a plan_digest, then call again with " <>
        "dry_run false and that digest to execute. Reconciles rather than replays — " <>
        "matching windows and panes are reused, only what is missing is added. " <>
        "It can never close a window or a pane, and never moves your focus. " <>
        "Casein owns placement — do not pass placement, size, position, pane_id, or " <>
        "window_id. An undo snapshot is saved automatically before anything executes.",
    category: "terminal",
    tags: ["terminal", "layout", "templates"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      template_id: [type: :string, required: true],
      session: [type: :string],
      dry_run: [type: :boolean],
      plan_digest: [type: :string],
      actor_id: [type: :string],
      caller_pane: [type: :string],
      # Declared only so ToolAction keeps them long enough for reject_placement/1.
      # Passing any of these is a hard error — agents declare intent, not geometry.
      placement: [type: :any],
      size: [type: :any],
      position: [type: :any],
      pane_id: [type: :any],
      window_id: [type: :any],
      geometry: [type: :any],
      focus: [type: :any],
      fraction: [type: :any],
      ratio: [type: :any]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.Helpers
  alias Casein.Agents.TerminalTools.Impl.Layout
  alias McpCtl.Tool

  @placement_keys ~w(placement size position pane_id window_id geometry focus fraction ratio)a

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(Helpers.workspace_props(), %{
        session: Helpers.session_param(),
        caller_pane: Helpers.caller_pane_param(),
        actor_id: Helpers.actor_id_param(),
        template_id: %{
          type: "string",
          description:
            "Saved template id to converge onto. Built-in templates cannot be reconciled " <>
              "(unsupported_reconcile) — snapshot the session first with " <>
              "terminal_layout_snapshot, or apply a saved export."
        },
        dry_run: %{
          type: "boolean",
          description:
            "Defaults to true. A dry run returns the plan and a plan_digest and changes " <>
              "nothing. Pass false together with that digest to execute."
        },
        plan_digest: %{
          type: "string",
          description:
            "The plan_digest from your dry run. Required to execute. If the layout moved " <>
              "since you planned, the digest no longer matches and the apply is refused " <>
              "(plan_stale) rather than run against a session you have not seen."
        }
      }),
      ["workspace_id", "template_id"]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_layout_apply")

  @impl Jido.Action
  def run(params, _context) do
    with :ok <- reject_placement(params) do
      Layout.apply_layout(Helpers.to_impl_args(params))
    end
  end

  defp reject_placement(params) when is_map(params) do
    forbidden =
      Enum.filter(@placement_keys, fn key ->
        Map.has_key?(params, key) and not is_nil(Map.get(params, key))
      end)

    case forbidden do
      [] ->
        :ok

      keys ->
        {:error,
         %{
           error: :placement_not_allowed,
           message:
             "terminal_layout_apply takes which layout, never where it goes. " <>
               "Rejected argument(s): #{Enum.map_join(keys, ", ", &Atom.to_string/1)}. " <>
               "Agents declare intent only; geometry and focus stay with the operator.",
           rejected: Enum.map(keys, &Atom.to_string/1)
         }}
    end
  end
end
