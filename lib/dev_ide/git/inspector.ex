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
    case GitCtl.Inspector.inspect_cwd(cwd) do
      {:ok, %GitCtl.Inspector{} = info} -> {:ok, from_git_ctl(info)}
      :error -> :error
    end
  end

  def inspect_cwd(_cwd), do: :error

  @spec infer_agent(String.t()) :: String.t() | nil
  defdelegate infer_agent(path), to: GitCtl.Inspector

  @doc false
  def cache_table, do: GitCtl.Cache.table()

  defp from_git_ctl(%GitCtl.Inspector{} = info) do
    struct(__MODULE__, Map.from_struct(info))
  end
end
