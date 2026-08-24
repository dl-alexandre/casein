defmodule Casein.Agents.CodeTools.Search do
  @moduledoc "code_search: bounded text search inside the assigned worktree."

  use Jido.Action,
    name: "code_search",
    description: "Search text in the assigned worktree with explicit match and byte caps.",
    category: "code",
    tags: ["code", "search"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      worktree_path: [type: :string, required: true],
      query: [type: :string, required: true],
      path: [type: :string],
      glob: [type: :string],
      max_matches: [type: :integer],
      max_bytes: [type: :integer],
      task_id: [type: :string],
      attempt_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.CodeTools.Helpers
  alias Casein.Files.PathSafety
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(
        %{
          workspace_id: Helpers.workspace_id_param(),
          worktree_path: Helpers.worktree_path_param(),
          query: %{type: "string", description: "Literal or regex text to search for."},
          path: %{
            type: "string",
            description: "Optional repository-relative directory or file to confine the search."
          },
          glob: %{type: "string", description: "Optional file glob passed to the searcher."},
          max_matches: %{
            type: "integer",
            minimum: 1,
            description: "Maximum matches to return (capped)."
          },
          max_bytes: %{
            type: "integer",
            minimum: 1,
            description: "Maximum bytes of match output to return (capped)."
          }
        },
        Helpers.identity_params()
      ),
      [:workspace_id, :worktree_path, :query]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata(:low, false)

  @impl Jido.Action
  def run(params, context) do
    with {:ok, assignment} <- Helpers.resolve_assignment(params, context),
         {:ok, search_rel} <- search_root(assignment.worktree_path, Map.get(params, :path)),
         {:ok, glob} <- normalize_glob(Map.get(params, :glob)) do
      limit = Helpers.clamp_search_limit(Map.get(params, :max_matches))
      max_bytes = Helpers.clamp_output_bytes(Map.get(params, :max_bytes))

      {matches, match_truncated?} =
        search(assignment.worktree_path, search_rel, params.query, glob, limit)

      encoded = Jason.encode!(matches)
      {_ignored, byte_truncated?} = Helpers.truncate_bytes(encoded, max_bytes)

      matches =
        if byte_truncated?, do: Enum.take(matches, max(div(length(matches), 2), 1)), else: matches

      {:ok,
       assignment
       |> Helpers.identity_fields()
       |> Map.merge(%{
         query: params.query,
         path: search_rel,
         glob: glob,
         matches: matches,
         match_count: length(matches),
         truncated: match_truncated? or byte_truncated?,
         match_truncated: match_truncated?,
         byte_truncated: byte_truncated?
       })}
    end
  end

  defp search_root(_worktree, nil), do: {:ok, "."}
  defp search_root(_worktree, ""), do: {:ok, "."}

  defp search_root(worktree, path) do
    with {:ok, rel, _abs} <- Helpers.resolve_rel_path(worktree, path) do
      {:ok, rel}
    end
  end

  defp normalize_glob(nil), do: {:ok, nil}
  defp normalize_glob(""), do: {:ok, nil}

  defp normalize_glob(glob) when is_binary(glob) do
    cond do
      String.contains?(glob, <<0>>) or String.contains?(glob, "\\") ->
        {:error, %{error: :invalid_glob, message: "glob may not contain NUL or backslashes"}}

      String.contains?(glob, "..") ->
        {:error, %{error: :invalid_glob, message: "glob may not contain .."}}

      true ->
        {:ok, glob}
    end
  end

  defp normalize_glob(_), do: {:error, %{error: :invalid_glob}}

  defp search(worktree, rel, query, glob, limit) do
    case System.find_executable("rg") do
      nil -> walk_search(worktree, rel, query, glob, limit)
      rg -> rg_search(rg, worktree, rel, query, glob, limit)
    end
  end

  # rg argv is constructed from validated relative path + literal query.
  # sobelow_skip ["CI.System"]
  defp rg_search(rg, worktree, rel, query, glob, limit) do
    args =
      [
        "--json",
        "--max-count",
        Integer.to_string(limit),
        "--max-filesize",
        "256K",
        "--glob",
        "!.git",
        "--glob",
        "!_build",
        "--glob",
        "!deps",
        "--glob",
        "!node_modules"
      ]
      |> maybe_glob(glob)
      |> Kernel.++(["--", query, rel])

    {output, _code} = System.cmd(rg, args, cd: worktree, stderr_to_stdout: true)
    parse_rg_json(output, limit)
  rescue
    _ -> walk_search(worktree, rel, query, glob, limit)
  end

  defp maybe_glob(args, nil), do: args
  defp maybe_glob(args, glob), do: args ++ ["--glob", glob]

  defp parse_rg_json(output, limit) do
    matches =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&decode_rg_line/1)
      |> Enum.take(limit)

    {matches, length(matches) >= limit}
  end

  defp decode_rg_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "match", "data" => data}} ->
        path = get_in(data, ["path", "text"])
        line_no = get_in(data, ["line_number"])
        text = get_in(data, ["lines", "text"]) || ""

        if is_binary(path) do
          [
            %{
              path: path,
              line: line_no,
              text: String.trim_trailing(text, "\n")
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp walk_search(worktree, rel, query, glob, limit) do
    root =
      case rel do
        "." -> worktree
        _ -> Path.join(worktree, rel)
      end

    matches =
      root
      |> list_files(worktree, glob)
      |> Enum.reduce_while([], fn file, acc ->
        acc = acc ++ file_matches(worktree, file, query, limit - length(acc))
        if length(acc) >= limit, do: {:halt, Enum.take(acc, limit)}, else: {:cont, acc}
      end)

    {matches, length(matches) >= limit}
  end

  defp list_files(root, worktree, glob) do
    cond do
      File.regular?(root) ->
        [root]

      File.dir?(root) ->
        Path.wildcard(Path.join(root, "**/*"), match_dot: false)
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(fn abs ->
          rel = Path.relative_to(abs, worktree)
          PathSafety.ignored?(rel) or not glob_match?(rel, glob)
        end)

      true ->
        []
    end
  end

  defp glob_match?(_rel, nil), do: true

  defp glob_match?(rel, glob) do
    basename = Path.basename(rel)
    wildcard_match?(basename, glob) or wildcard_match?(rel, glob)
  end

  defp wildcard_match?(name, glob) do
    regex =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")
      |> then(&("^" <> &1 <> "$"))
      |> Regex.compile!()

    Regex.match?(regex, name)
  rescue
    _ -> false
  end

  # abs is a Path.wildcard result under a worktree-confined root.
  # sobelow_skip ["Traversal.FileModule"]
  defp file_matches(worktree, abs, query, remaining) when remaining > 0 do
    case File.read(abs) do
      {:ok, content} when byte_size(content) <= 256 * 1024 ->
        if PathSafety.likely_binary?(content) do
          []
        else
          rel = Path.relative_to(abs, worktree)

          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> String.contains?(line, query) end)
          |> Enum.take(remaining)
          |> Enum.map(fn {line, n} -> %{path: rel, line: n, text: line} end)
        end

      _ ->
        []
    end
  end

  defp file_matches(_worktree, _abs, _query, _remaining), do: []
end
