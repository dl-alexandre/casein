defmodule GitCtl.Inspector do
  @moduledoc """
  Git inspection for worktree detection and context.

  Uses absolute paths via `--path-format=absolute` so linked worktrees and
  `.git` file pointers resolve consistently.
  """

  alias GitCtl.Cache

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
  executed. Results are cached per cwd for `:git_ctl :cache_ttl_ms`.
  """
  @spec inspect_cwd(String.t()) :: {:ok, t()} | :error
  def inspect_cwd(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    ttl = Cache.ttl_ms()

    with true <- ttl > 0,
         {:ok, cached} <- Cache.lookup(cwd, ttl) do
      cached
    else
      _ ->
        result = run_inspect(cwd)
        if ttl > 0, do: Cache.store(cwd, result)
        result
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

  defp run_inspect(cwd) do
    with true <- File.dir?(cwd),
         {:ok, context} <- git_context(cwd),
         {:ok, head_sha} <- git_rev_parse(cwd, ["--verify", "--short", "HEAD"]) do
      head_sha = String.trim(head_sha)

      {branch, detached?} =
        if context.ref in ["HEAD", ""], do: {head_sha, true}, else: {context.ref, false}

      {:ok,
       %__MODULE__{
         toplevel: context.toplevel,
         git_dir: context.git_dir,
         git_common_dir: context.git_common_dir,
         branch: branch,
         head_sha: head_sha,
         worktree?: context.git_dir != context.git_common_dir,
         detached?: detached?,
         agent: infer_agent(cwd)
       }}
    else
      _ -> :error
    end
  end

  defp git_context(cwd) do
    args = [
      "rev-parse",
      "--path-format=absolute",
      "--show-toplevel",
      "--git-dir",
      "--git-common-dir",
      "--symbolic-full-name",
      "--abbrev-ref",
      "HEAD"
    ]

    with {out, 0} <- System.cmd("git", args, cd: cwd),
         [toplevel, git_dir, git_common_dir, ref] <-
           out |> String.trim_trailing("\n") |> String.split("\n") do
      {:ok,
       %{
         toplevel: clean_path(toplevel),
         git_dir: clean_path(git_dir),
         git_common_dir: clean_path(git_common_dir),
         ref: String.trim(ref)
       }}
    else
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp git_rev_parse(cwd, args) do
    case System.cmd("git", ["rev-parse" | args], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp clean_path(path), do: path |> String.trim() |> Path.expand()
end
