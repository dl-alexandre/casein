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
    agent: nil,
    upstream: nil,
    ahead: nil,
    behind: nil
  ]

  @type t :: %__MODULE__{
          toplevel: String.t(),
          git_dir: String.t(),
          git_common_dir: String.t(),
          branch: String.t(),
          head_sha: String.t(),
          worktree?: boolean(),
          detached?: boolean(),
          agent: String.t() | nil,
          upstream: String.t() | nil,
          ahead: non_neg_integer() | nil,
          behind: non_neg_integer() | nil
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

  # Agent naming is host-application policy, not git inspection. Hosts inject
  # it via `config :git_ctl, agent_inference: {mod, fun}` (or a 1-arity fun);
  # without it the :agent field stays nil.
  defp infer_agent(cwd) do
    case Application.get_env(:git_ctl, :agent_inference) do
      {mod, fun} -> apply(mod, fun, [cwd])
      fun when is_function(fun, 1) -> fun.(cwd)
      _ -> nil
    end
  end

  defp run_inspect(cwd) do
    with true <- File.dir?(cwd),
         {:ok, context} <- git_context(cwd),
         {:ok, head_sha} <- git_rev_parse(cwd, ["--verify", "--short", "HEAD"]) do
      head_sha = String.trim(head_sha)

      {branch, detached?} =
        if context.ref in ["HEAD", ""], do: {head_sha, true}, else: {context.ref, false}

      {upstream, ahead, behind} =
        if detached?, do: {nil, nil, nil}, else: upstream_counts(cwd)

      {:ok,
       %__MODULE__{
         toplevel: context.toplevel,
         git_dir: context.git_dir,
         git_common_dir: context.git_common_dir,
         branch: branch,
         head_sha: head_sha,
         worktree?: context.git_dir != context.git_common_dir,
         detached?: detached?,
         agent: infer_agent(cwd),
         upstream: upstream,
         ahead: ahead,
         behind: behind
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

  # Ahead/behind vs the branch's configured upstream, via a single
  # `rev-list --left-right --count @{upstream}...HEAD` (left = behind,
  # right = ahead). Branches with no upstream configured — and bare or broken
  # checkouts where the lookup fails for any reason — report nils rather than
  # turning the whole inspection into an error.
  defp upstream_counts(cwd) do
    with {:ok, upstream} <-
           git_rev_parse(cwd, ["--abbrev-ref", "--symbolic-full-name", "@{upstream}"]),
         {counts, 0} <-
           System.cmd("git", ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
             cd: cwd,
             stderr_to_stdout: true
           ),
         [behind, ahead] <- counts |> String.trim() |> String.split() do
      {String.trim(upstream), String.to_integer(ahead), String.to_integer(behind)}
    else
      _ -> {nil, nil, nil}
    end
  rescue
    _ -> {nil, nil, nil}
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
