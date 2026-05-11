defmodule DevIDE.Search.MemoryAdapter do
  @moduledoc """
  Test-only search adapter. Reads canned results from
  `Application.get_env(:dev_ide, :search_memory_results, %{})` keyed by query.
  Setting `:available?` to `false` simulates a missing ripgrep binary.
  """

  @behaviour DevIDE.Search

  @impl true
  def available?, do: Application.get_env(:dev_ide, :search_memory_available, true)

  @impl true
  def search(root, query, _opts) do
    case Application.get_env(:dev_ide, :search_memory_response, nil) do
      nil ->
        results =
          :dev_ide
          |> Application.get_env(:search_memory_results, %{})
          |> Map.get(query, [])

        {:ok, Enum.map(results, &normalize(&1, root))}

      {:error, _} = err ->
        err

      list when is_list(list) ->
        {:ok, Enum.map(list, &normalize(&1, root))}
    end
  end

  defp normalize(%DevIDE.Search.Result{} = r, _), do: r

  defp normalize(map, _root) when is_map(map) do
    struct(DevIDE.Search.Result, map)
  end
end
