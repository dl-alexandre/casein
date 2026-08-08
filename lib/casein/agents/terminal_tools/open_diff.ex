defmodule Casein.Agents.TerminalTools.OpenDiff do
  @moduledoc "diff_open — one-shot intent to surface a git diff to the human."

  use Jido.Action,
    name: "diff_open",
    description:
      "Surface a git diff to the connected Casein cockpit viewer (one-shot intent). " <>
        "Pass workspace_id and optionally a workspace-relative path to focus. " <>
        "Casein owns placement — do not pass placement, size, position, or pane_id. " <>
        "If nobody is watching the workspace this is a no-op (status no_viewer). " <>
        "Returns immediately; there is no pane handle to drive afterwards.",
    category: "terminal",
    tags: ["terminal", "diff", "inspectors"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      path: [type: :string],
      # Declared only so ToolAction keeps them long enough for reject_placement/1.
      # Passing any of these is a hard error — agents declare intent, not geometry.
      placement: [type: :any],
      size: [type: :any],
      position: [type: :any],
      pane_id: [type: :any],
      geometry: [type: :any],
      focus: [type: :any],
      fraction: [type: :any],
      ratio: [type: :any]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.Helpers
  alias Casein.Agents.TerminalTools.Impl.Command
  alias McpCtl.Tool

  @placement_keys ~w(placement size position pane_id geometry focus fraction ratio)a

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(Helpers.workspace_props(), %{
        path: %{
          type: "string",
          description:
            "Optional workspace-relative path to focus in the diff (e.g. \"lib/foo.ex\"). " <>
              "Omit to open the workspace diff overview. Paths are re-validated server-side."
        }
      }),
      ["workspace_id"]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("diff_open")

  @impl Jido.Action
  def run(params, _context) do
    with :ok <- reject_placement(params) do
      Command.open_diff(Helpers.to_impl_args(params))
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
             "diff_open takes what to open, never where. " <>
               "Rejected placement argument(s): #{Enum.map_join(keys, ", ", &Atom.to_string/1)}. " <>
               "Agents declare intent only; Casein owns placement/geometry.",
           rejected: Enum.map(keys, &Atom.to_string/1)
         }}
    end
  end
end
