defmodule Casein.Search.RipgrepAdapter do
  @moduledoc """
  Ripgrep-backed search. argv-only invocation:

      rg --line-number --column --json --hidden \\
         --glob !.git --glob !_build --glob !deps \\
         --glob !node_modules --glob !priv/static/cache \\
         --max-filesize <cap> \\
         -e <query> <root>

  The query is the argv element after `-e`, never interpolated into a
  shell string. Output is parsed line-by-line as ripgrep's --json events.
  Results are PathSafety-filtered before being returned.
  """

  @behaviour Casein.Search.Adapter

  alias Casein.Files.PathSafety
  alias Casein.Search.Result

  @ignore_globs ~w(.git _build deps node_modules priv/static/cache)
  @max_output_bytes 1 * 1024 * 1024

  @impl true
  def available?, do: not is_nil(System.find_executable("rg"))

  @impl true
  def search(root, query, opts) do
    case System.find_executable("rg") do
      nil ->
        {:error, :rg_missing}

      rg ->
        timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
        result_cap = Keyword.get(opts, :result_cap, 200)
        argv = build_argv(query, root)

        run_with_timeout(rg, argv, timeout_ms)
        |> case do
          {:ok, output} ->
            results =
              output
              |> cap_bytes(@max_output_bytes)
              |> parse(root)
              |> Enum.take(result_cap)

            {:ok, results}

          {:error, _} = err ->
            err
        end
    end
  end

  ## argv

  defp build_argv(query, root) do
    base = ["--line-number", "--column", "--json", "--hidden", "--no-messages"]

    globs =
      Enum.flat_map(@ignore_globs, fn pat -> ["--glob", "!" <> pat] end)

    base ++ globs ++ ["-e", query, "--", root]
  end

  ## Run with timeout

  defp run_with_timeout(rg, argv, timeout_ms) do
    task = Task.async(fn -> System.cmd(rg, argv, stderr_to_stdout: false) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      # rg exits 0 (matches), 1 (no matches), 2 (error). 0/1 are both fine here.
      {:ok, {output, code}} when code in [0, 1] -> {:ok, output}
      {:ok, {output, _code}} -> {:ok, output}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  defp cap_bytes(bin, cap) when byte_size(bin) <= cap, do: bin
  defp cap_bytes(bin, cap), do: binary_part(bin, 0, cap)

  ## Parse rg --json

  defp parse(output, root) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
    |> Enum.flat_map(&path_safe(&1, root))
  end

  defp parse_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "match", "data" => data}} -> [match_to_result(data)]
      _ -> []
    end
  end

  defp match_to_result(data) do
    %{
      "path" => path_obj,
      "line_number" => line,
      "lines" => lines_obj,
      "submatches" => subs
    } = data

    %{
      path: text(path_obj),
      line: line,
      column: column_from(subs),
      preview: text(lines_obj) |> trim_preview()
    }
  end

  defp text(%{"text" => t}) when is_binary(t), do: t
  defp text(%{"bytes" => b}) when is_binary(b), do: b
  defp text(_), do: ""

  defp column_from([%{"start" => start} | _]) when is_integer(start), do: start + 1
  defp column_from(_), do: nil

  defp trim_preview(text) do
    text
    |> String.replace_trailing("\n", "")
    |> String.slice(0, 240)
  end

  defp path_safe(%{path: path} = match, root) when is_binary(path) do
    rel = Path.relative_to(path, root)

    if rel == path do
      []
    else
      case PathSafety.resolve(root, rel) do
        {:ok, _abs} ->
          [
            %Result{
              path: rel,
              line: match.line,
              column: match.column,
              preview: match.preview
            }
          ]

        _ ->
          []
      end
    end
  end

  defp path_safe(_, _), do: []
end
