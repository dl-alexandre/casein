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

  @cache_table :devide_git_inspector_cache
  @default_cache_ttl_ms 10_000

  @doc """
  Inspects a cwd and returns Git checkout/worktree context.

  Returns `:error` when `cwd` is missing, not a Git checkout, or Git cannot be
  executed.

  Results (including `:error`) are cached per cwd for
  `:git_inspector_cache_ttl_ms` (default #{@default_cache_ttl_ms}ms): callers
  like `SessionDirectory` re-inspect the same cwds on every 2s poll, and the
  underlying repo state rarely changes between ticks. Set the TTL to `0` to
  bypass the cache (test config does).
  """
  @spec inspect_cwd(String.t()) :: {:ok, t()} | :error
  def inspect_cwd(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    ttl = cache_ttl_ms()

    with true <- ttl > 0,
         {:ok, cached} <- cache_lookup(cwd, ttl) do
      cached
    else
      _ ->
        result = run_inspect(cwd)
        if ttl > 0, do: cache_store(cwd, result)
        result
    end
  end

  def inspect_cwd(_cwd), do: :error

  @doc false
  def cache_table, do: @cache_table

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

  # One subprocess for everything but the sha: rev-parse emits one line per
  # query flag, in argument order; detached HEAD prints the literal "HEAD".
  # The sha cannot ride along — the `--abbrev-ref` modifier sticks to any
  # later rev argument, so `--short HEAD` would print the ref again.
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

    # No stderr_to_stdout here: the output is parsed line-positionally and a
    # stray git warning would corrupt the fields.
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

  defp cache_lookup(cwd, ttl) do
    case :ets.lookup(@cache_table, cwd) do
      [{^cwd, result, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at <= ttl do
          {:ok, result}
        else
          :miss
        end

      _ ->
        :miss
    end
  rescue
    # Table absent (cache process not started, e.g. bare unit runs).
    ArgumentError -> :miss
  end

  defp cache_store(cwd, result) do
    :ets.insert(@cache_table, {cwd, result, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cache_ttl_ms do
    Application.get_env(:dev_ide, :git_inspector_cache_ttl_ms, @default_cache_ttl_ms)
  end

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

  defp clean_path(path), do: path |> String.trim() |> Path.expand()
end
