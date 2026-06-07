defmodule DevIDE.Git.LocalAdapter do
  @moduledoc """
  Local-host git adapter. Shells out to the `git` binary using **argv-style**
  invocation (no shell interpolation). All path arguments must be relative
  and validated via `DevIDE.Files.PathSafety` before reaching this module.

  All commands run with `git -C <root>` so the workspace root is the only
  cwd assumption.
  """

  @behaviour DevIDE.Git.Adapter

  alias DevIDE.Files.PathSafety

  @max_diff_bytes 256 * 1024

  @impl true
  def status_short(root) when is_binary(root) do
    case run(root, ["status", "--short", "--untracked-files=all"]) do
      {:ok, out} -> {:ok, parse_status(out)}
      err -> err
    end
  end

  @impl true
  def diff(root, rel) when is_binary(root) and is_binary(rel) do
    with {:ok, _abs} <- PathSafety.resolve(root, rel),
         {:ok, out} <- run(root, ["diff", "--no-color", "--", rel]) do
      {:ok, cap(out)}
    end
  end

  @impl true
  def diff_all(root) when is_binary(root) do
    with {:ok, out} <- run(root, ["diff", "--no-color"]) do
      {:ok, cap(out)}
    end
  end

  defp run(root, args) do
    git = System.find_executable("git")

    cond do
      is_nil(git) ->
        {:error, :git_not_found}

      not File.dir?(root) ->
        {:error, :no_root}

      true ->
        case System.cmd(git, ["-C", root | args], stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, code} -> {:error, {:git_exit, code, cap(out)}}
        end
    end
  end

  defp parse_status(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      <<x::utf8, y::utf8, " ", path::binary>> = line
      %{x: <<x::utf8>>, y: <<y::utf8>>, path: path}
    end)
  end

  defp cap(s) when byte_size(s) > @max_diff_bytes do
    <<head::binary-size(@max_diff_bytes), _::binary>> = s
    head <> "\n... [diff truncated]"
  end

  defp cap(s), do: s
end
