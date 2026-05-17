defmodule DevIDE.Terminals.InspectionCommands do
  @moduledoc """
  Read-only governed terminal commands.

  These are not shell commands. Lines are parsed into argv, matched against a
  small read-only registry, and executed directly in the workspace root with
  bounded runtime and output.
  """

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
      "rg pattern"
    ]
  end

  @spec run(String.t(), String.t()) :: {:ok, result()} | {:error, atom() | term()}
  def run(root, line) when is_binary(root) and is_binary(line) do
    with {:ok, argv} <- split_argv(line),
         {:ok, argv} <- normalize(argv),
         :ok <- safe_root(root),
         {:ok, bin} <- executable(List.first(argv)) do
      execute(root, [bin | tl(argv)], line)
    end
  end

  def run(_, _), do: {:error, :not_allowed}

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
