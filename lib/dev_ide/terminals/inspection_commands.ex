defmodule DevIDE.Terminals.InspectionCommands do
  @moduledoc """
  Read-only governed terminal commands.

  These are not shell commands. Lines are parsed into argv, matched against a
  small read-only registry, and executed directly in the workspace root with
  bounded runtime and output.
  """

  alias DevIDE.Previews

  @max_output 64 * 1024

  @type result :: %{
          status: String.t(),
          line: String.t(),
          argv: [String.t()],
          exit_code: non_neg_integer() | term(),
          output: String.t(),
          output_truncated: boolean()
        }

  @doc "Examples shown by governed terminal help."
  @spec examples() :: [String.t()]
  def examples do
    [
      "pwd",
      "ls",
      "ls lib",
      "git status --short",
      "rg pattern",
      "tidewave",
      "preview surfaces",
      "preview open app-local"
    ]
  end

  @spec run(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, atom() | term()}
  def run(root, line, opts \\ [])

  def run(root, line, opts) when is_binary(root) and is_binary(line) and is_list(opts) do
    with {:ok, argv} <- split_argv(line),
         :ok <- safe_root(root) do
      case argv do
        ["preview" | _] = preview_argv ->
          preview_command(line, preview_argv, opts)

        ["tidewave"] ->
          tidewave_status(root, line, Keyword.get(opts, :workspace))

        ["tidewave", "status"] ->
          tidewave_status(root, line, Keyword.get(opts, :workspace))

        _ ->
          run_filesystem_command(root, line, argv)
      end
    end
  end

  def run(_, _, _), do: {:error, :not_allowed}

  defp preview_command(line, argv, opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_map(workspace) ->
        Previews.run(workspace, line, argv, opts)

      _ ->
        {:error, :not_allowed}
    end
  end

  defp split_argv(line) do
    case OptionParser.split(line) do
      [] -> {:error, :blank}
      argv -> {:ok, argv}
    end
  rescue
    _ -> {:error, :not_allowed}
  catch
    _, _ -> {:error, :not_allowed}
  end

  defp normalize(["pwd"]), do: {:ok, ["pwd"]}
  defp normalize(["ls"]), do: {:ok, ["ls", "-la"]}
  defp normalize(["ls", path]), do: safe_relative_path(path, fn -> ["ls", "-la", path] end)
  defp normalize(["git", "status"]), do: {:ok, ["git", "status", "--short"]}
  defp normalize(["git", "status", "--short"]), do: {:ok, ["git", "status", "--short"]}

  defp normalize(["rg", pattern]) when is_binary(pattern) and pattern != "",
    do: {:ok, ["rg", "--line-number", "--color", "never", pattern]}

  defp normalize(_), do: {:error, :not_allowed}

  defp run_filesystem_command(root, line, argv) do
    with {:ok, argv} <- normalize(argv),
         {:ok, bin} <- executable(List.first(argv)) do
      execute(root, [bin | tl(argv)], line)
    end
  end

  defp tidewave_status(root, line, workspace) do
    caps = DevIDE.WorkspaceSource.detect_capabilities(workspace || %{}, root)

    cap =
      Enum.find(caps, &(&1.kind == :tidewave)) ||
        %DevIDE.Agents.Capability{kind: :tidewave, status: :missing}

    output =
      case cap.status do
        :detected ->
          [
            "Tidewave: detected",
            "URL: #{cap.url || "(no url advertised)"}",
            "Source: #{cap.source || "(unknown)"}",
            "Details: #{inspect(cap.details || %{})}",
            "Debug use: inspect runtime state, routes, processes, logs, and framework context from the Tidewave endpoint."
          ]
          |> Enum.join("\n")

        _ ->
          tidewave_missing_lines()
          |> Enum.join("\n")
      end

    {:ok,
     %{
       status: "completed",
       line: line,
       argv: ["tidewave"],
       exit_code: 0,
       output: output <> "\n",
       output_truncated: false
     }}
  end

  defp tidewave_missing_lines do
    base = [
      "Tidewave: missing",
      "No Tidewave endpoint on this DevIDE instance (prod release excludes the :tidewave dep).",
      "Workspace apps: expected manager metadata domain_base plus ports.tidewave.",
      "DevIDE preview: run scripts/preview-env.sh up — Tidewave is available on the allocated loopback port."
    ]

    preview_lines =
      Previews.running_instances()
      |> Enum.flat_map(fn inst ->
        case Previews.tidewave_mcp_url(inst) do
          url when is_binary(url) ->
            ["  #{inst["id"]}: #{url}"]

          _ ->
            []
        end
      end)

    case preview_lines do
      [] ->
        base

      _ ->
        base ++ ["Active preview environments (dev-only Tidewave MCP):"] ++ preview_lines
    end
  end

  defp safe_root(root) do
    if File.dir?(root), do: :ok, else: {:error, :no_root}
  end

  defp safe_relative_path(path, fun) do
    cond do
      path in ["", ".", "./"] ->
        {:ok, fun.()}

      Path.type(path) == :absolute ->
        {:error, :outside_root}

      path |> Path.expand("/") |> String.starts_with?("/../") ->
        {:error, :outside_root}

      String.split(path, "/", trim: true) |> Enum.any?(&(&1 == "..")) ->
        {:error, :outside_root}

      true ->
        {:ok, fun.()}
    end
  end

  defp executable(bin) do
    case System.find_executable(bin) do
      nil -> {:error, {:executable_not_found, bin}}
      path -> {:ok, path}
    end
  end

  # sobelow_skip ["CI.System"]
  defp execute(root, argv, line) do
    {output, exit_code} =
      System.cmd(List.first(argv), tl(argv),
        cd: root,
        stderr_to_stdout: true,
        env: [{"TERM", "dumb"}]
      )

    {output, truncated?} = cap_output(output)

    {:ok,
     %{
       status: "completed",
       line: line,
       argv: argv,
       exit_code: exit_code,
       output: output,
       output_truncated: truncated?
     }}
  rescue
    e in ErlangError -> {:error, e.original}
  catch
    :exit, reason -> {:error, reason}
  end

  defp cap_output(output) when byte_size(output) <= @max_output, do: {output, false}

  defp cap_output(output) do
    keep = binary_part(output, 0, @max_output)
    {keep <> "\n[output truncated]\n", true}
  end
end
