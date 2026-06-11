defmodule DevIDE.Git.Inspector do
  @moduledoc """
  Git inspection for worktree detection and context in DevIDE.

  Uses absolute paths via `--path-format=absolute` so linked worktrees and
  `.git` file pointers resolve consistently.
  """

  defstruct [
    :toplevel,
    :git_dir,
    :git_common_dir,
    :branch,
    :head_sha,
    worktree?: false,
    detached?: false,
    agent: nil
  ]

  @type t :: %__MODULE__{
          toplevel: String.t(),
          git_dir: String.t(),
          git_common_dir: String.t(),
          branch: String.t(),
          head_sha: String.t(),
          worktree?: boolean(),
          detached?: boolean(),
          agent: String.t() | nil
        }

  @doc """
  Inspects a cwd and returns Git checkout/worktree context.

  Returns `:error` when `cwd` is missing, not a Git checkout, or Git cannot be
  executed.
  """
  @spec inspect_cwd(String.t()) :: {:ok, t()} | :error
  def inspect_cwd(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)

    with true <- File.dir?(cwd),
         {:ok, toplevel} <- git_rev_parse(cwd, ["--path-format=absolute", "--show-toplevel"]),
         {:ok, git_dir} <- git_rev_parse(cwd, ["--path-format=absolute", "--git-dir"]),
         {:ok, git_common_dir} <-
           git_rev_parse(cwd, ["--path-format=absolute", "--git-common-dir"]),
         {:ok, branch, detached?} <- git_branch_or_head(cwd),
         {:ok, head_sha} <- git_rev_parse(cwd, ["--verify", "--short", "HEAD"]) do
      git_dir = clean_path(git_dir)
      git_common_dir = clean_path(git_common_dir)

      {:ok,
       %__MODULE__{
         toplevel: clean_path(toplevel),
         git_dir: git_dir,
         git_common_dir: git_common_dir,
         branch: branch,
         head_sha: String.trim(head_sha),
         worktree?: git_dir != git_common_dir,
         detached?: detached?,
         agent: infer_agent(cwd)
       }}
    else
      _ -> :error
    end
  end

  def inspect_cwd(_cwd), do: :error

  @doc "Infer the agent/runtime from common worktree path patterns."
  @spec infer_agent(String.t()) :: String.t() | nil
  def infer_agent(path) when is_binary(path) do
    path = String.downcase(path)

    cond do
      String.contains?(path, "/opencode/") -> "opencode"
      String.contains?(path, "/.claude/") -> "claude"
      String.contains?(path, "grok") -> "grok"
      String.contains?(path, "/codex/") or String.contains?(path, "codex") -> "codex"
      true -> nil
    end
  end

  def infer_agent(_path), do: nil

  defp git_rev_parse(cwd, args) do
    case System.cmd("git", ["rev-parse" | args], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp git_branch_or_head(cwd) do
    case git_rev_parse(cwd, ["--symbolic-full-name", "--abbrev-ref", "HEAD"]) do
      {:ok, ref} ->
        ref = String.trim(ref)

        if ref == "HEAD" or ref == "" do
          git_detached_head(cwd)
        else
          {:ok, ref, false}
        end

      :error ->
        git_detached_head(cwd)
    end
  end

  defp git_detached_head(cwd) do
    case git_rev_parse(cwd, ["--short", "HEAD"]) do
      {:ok, ref} -> {:ok, String.trim(ref), true}
      :error -> :error
    end
  end

  defp clean_path(path), do: path |> String.trim() |> Path.expand()
end
