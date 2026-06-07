defmodule DevIDE.Search do
  @moduledoc """
  Cross-file workspace search.

  Argv-only. The query is an argv element, never a shell string. The
  workspace root is supplied by the caller (already resolved via
  `Workspaces.safe_host_path/1`). Results are filtered through
  `DevIDE.Files.PathSafety.resolve/2` before reaching the UI — anything
  that would point outside the workspace root is dropped.

  M18 contract: search-only. No replace, no write, no callback that mutates
  files.
  """

  alias DevIDE.Search.Result

  @min_query 2
  @max_query 200
  @default_timeout_ms 10_000
  @result_cap 200

  @spec search(String.t(), String.t(), keyword()) ::
          {:ok, [Result.t()]} | {:error, term()}
  def search(root, query, opts \\ []) when is_binary(root) and is_binary(query) do
    cond do
      String.length(query) < @min_query -> {:error, :too_short}
      String.length(query) > @max_query -> {:error, :too_long}
      not File.dir?(root) -> {:error, :no_root}
      true -> impl().search(root, query, Keyword.merge(default_opts(), opts))
    end
  end

  def available?, do: impl().available?()

  def min_query, do: @min_query
  def max_query, do: @max_query
  def result_cap, do: @result_cap

  defp default_opts,
    do: [timeout_ms: @default_timeout_ms, result_cap: @result_cap]

  defp impl,
    do: Application.get_env(:dev_ide, :search_adapter, DevIDE.Search.RipgrepAdapter)
end
