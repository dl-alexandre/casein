defmodule Casein.Agents.CodeTools.Read do
  @moduledoc "code_read: bounded file/range read inside the assigned worktree."

  use Jido.Action,
    name: "code_read",
    description:
      "Read a repository-relative file (optionally a line range) from the assigned worktree.",
    category: "code",
    tags: ["code", "read"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      worktree_path: [type: :string, required: true],
      path: [type: :string, required: true],
      start_line: [type: :integer],
      end_line: [type: :integer],
      max_bytes: [type: :integer],
      task_id: [type: :string],
      attempt_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.CodeTools.Helpers
  alias Casein.Files
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(
        %{
          workspace_id: Helpers.workspace_id_param(),
          worktree_path: Helpers.worktree_path_param(),
          path: Helpers.path_param(),
          start_line: %{
            type: "integer",
            minimum: 1,
            description: "1-based first line to return (inclusive)."
          },
          end_line: %{
            type: "integer",
            minimum: 1,
            description: "1-based last line to return (inclusive)."
          },
          max_bytes: %{
            type: "integer",
            minimum: 1,
            description: "Maximum bytes of content to return (capped)."
          }
        },
        Helpers.identity_params()
      ),
      [:workspace_id, :worktree_path, :path]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata(:low, false)

  @impl Jido.Action
  def run(params, context) do
    with {:ok, assignment} <- Helpers.resolve_assignment(params, context),
         {:ok, rel, _abs} <- Helpers.resolve_rel_path(assignment.worktree_path, params.path),
         {:ok, file} <- read_file(assignment.worktree_path, rel) do
      max_bytes = Helpers.clamp_output_bytes(Map.get(params, :max_bytes))
      {content, line_start, line_end, line_truncated?} = slice_lines(file.content, params)
      {content, byte_truncated?} = Helpers.truncate_bytes(content, max_bytes)

      {:ok,
       assignment
       |> Helpers.identity_fields()
       |> Map.merge(%{
         path: rel,
         content: content,
         size: file.size,
         start_line: line_start,
         end_line: line_end,
         truncated: byte_truncated? or line_truncated?,
         byte_truncated: byte_truncated?,
         range_truncated: line_truncated?
       })}
    end
  end

  defp read_file(root, rel) do
    case Files.read_text(root, rel) do
      {:ok, file} -> {:ok, file}
      {:error, reason} -> {:error, read_error(rel, reason)}
    end
  end

  defp read_error(rel, reason) when is_atom(reason) do
    %{error: reason, path: rel, message: "Unable to read #{inspect(rel)} (#{reason})"}
  end

  defp read_error(rel, reason) do
    %{error: :read_failed, path: rel, reason: inspect(reason)}
  end

  defp slice_lines(content, params) do
    lines = String.split(content, "\n")
    total = length(lines)
    start_line = normalize_line(Map.get(params, :start_line), 1, total)
    end_line = normalize_line(Map.get(params, :end_line), total, total)

    {start_line, end_line} =
      if start_line > end_line, do: {end_line, start_line}, else: {start_line, end_line}

    sliced = lines |> Enum.slice((start_line - 1)..(end_line - 1)) |> Enum.join("\n")
    {sliced, start_line, end_line, start_line > 1 or end_line < total}
  end

  defp normalize_line(value, _default, total) when is_integer(value) and value > 0 do
    min(value, max(total, 1))
  end

  defp normalize_line(_value, default, total), do: min(default, max(total, 1))
end
