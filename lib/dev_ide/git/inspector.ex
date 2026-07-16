defmodule DevIDE.Git.Inspector do
  @moduledoc """
  Git inspection for worktree detection and context in DevIDE.

  Delegates subprocess parsing and ETS caching to `GitCtl.Inspector`.
  """

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
    case GitCtl.Inspector.inspect_cwd(cwd) do
      {:ok, %GitCtl.Inspector{} = info} -> {:ok, from_git_ctl(info)}
      :error -> :error
    end
  end

  def inspect_cwd(_cwd), do: :error

  @doc """
  Infer the agent/runtime from common worktree path patterns.

  This is DevIDE workspace policy, injected into `GitCtl` via the
  `:git_ctl :agent_inference` config so inspection results carry it.
  """
  @spec infer_agent(String.t() | term()) :: String.t() | nil
  def infer_agent(path) when is_binary(path) do
    path = String.downcase(path)

    cond do
      String.contains?(path, "/opencode/") -> "opencode"
      String.contains?(path, "/.claude/") -> "claude"
      String.contains?(path, "grok") -> "grok"
      String.contains?(path, "codex") -> "codex"
      true -> nil
    end
  end

  def infer_agent(_path), do: nil

  @doc false
  def cache_table, do: GitCtl.Cache.table()

  @after_compile __MODULE__

  # `struct/2` silently drops unknown keys, so field drift between this facade
  # and GitCtl.Inspector would otherwise go unnoticed until runtime.
  def __after_compile__(%{module: module, file: file, line: line}, _bytecode) do
    facade_fields = module.__struct__() |> Map.keys() |> Enum.sort()
    git_ctl_fields = GitCtl.Inspector.__struct__() |> Map.keys() |> Enum.sort()

    if facade_fields != git_ctl_fields do
      raise CompileError,
        description:
          "DevIDE.Git.Inspector struct fields must mirror GitCtl.Inspector — update both structs",
        file: file,
        line: line
    end
  end

  defp from_git_ctl(%GitCtl.Inspector{} = info) do
    struct(__MODULE__, Map.from_struct(info))
  end
end
