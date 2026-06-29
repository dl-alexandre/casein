defmodule DevIDE.CommandPalette do
  @moduledoc """
  Public facade for the command palette: query → ranked items.

  Files are sourced from `CommandPalette.FileIndex` (capped, ignored-dirs-aware,
  symlinks not followed). Actions/commands/tabs come from `CommandPalette.Actions`,
  a fixed allowlist. The palette **never** synthesises a free-form command
  — selecting a result dispatches one of the existing gated LiveView events.
  """

  alias DevIDE.CommandPalette.{Actions, FileIndex, Fuzzy, Item}

  @max_results 50

  @spec query(String.t() | nil, String.t() | nil, keyword()) :: [Item.t()]
  def query(root, q, opts \\ [])

  # query/3 searches file/action palette data only; root never reaches SQL.
  # sobelow_skip ["SQL.Query"]
  def query(root, nil, opts), do: query(root, "", opts)

  # query/3 searches file/action palette data only; root never reaches SQL.
  # sobelow_skip ["SQL.Query"]
  def query(root, q, opts) when is_binary(q) do
    limit = Keyword.get(opts, :limit, @max_results)
    category = Keyword.get(opts, :category, :all)

    # Skip the FileIndex scan entirely when a non-file category is selected.
    file_items =
      if is_binary(root) and category in [:all, :files], do: file_items(root, q), else: []

    action_items = action_items(q)

    (file_items ++ action_items)
    |> filter_by_category(category)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp filter_by_category(items, :all), do: items

  defp filter_by_category(items, category),
    do: Enum.filter(items, &(Item.category(&1) == category))

  defp file_items(root, q) do
    FileIndex.list(root)
    |> Enum.flat_map(fn rel ->
      case Fuzzy.score(rel, q) do
        nil ->
          []

        s ->
          [
            %Item{
              id: "file:" <> rel,
              kind: :file,
              label: rel,
              detail: "Open file",
              score: s,
              payload: %{event: "annotation:open", params: %{"path" => rel}}
            }
          ]
      end
    end)
  end

  defp action_items(q) do
    Enum.flat_map(Actions.all(), fn item ->
      case Fuzzy.score(item.label, q) do
        nil -> []
        s -> [%{item | score: s}]
      end
    end)
  end

  @doc """
  Resolve an item id submitted from the wire back to its allowlisted payload.

  Returns `:error` if the id refers to nothing in the current allowlist or
  to a file that fails `PathSafety.resolve/2` against `root`.
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: {:ok, map()} | :error
  def resolve(_root, nil), do: :error

  def resolve(root, "file:" <> rel) when is_binary(root) and is_binary(rel) do
    case DevIDE.Files.PathSafety.resolve(root, rel) do
      {:ok, _} -> {:ok, %{event: "annotation:open", params: %{"path" => rel}}}
      _ -> :error
    end
  end

  def resolve(_root, id) when is_binary(id) do
    Actions.all()
    |> Enum.find(&(&1.id == id))
    |> case do
      nil ->
        :error

      %Item{payload: %{event: ev} = payload} ->
        if ev in Actions.allowed_events(), do: {:ok, payload}, else: :error
    end
  end
end
