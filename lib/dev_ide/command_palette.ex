defmodule DevIDE.CommandPalette do
  @moduledoc """
  Public facade for the command palette: query → ranked items.

  Files are sourced from `CommandPalette.FileIndex` (capped, ignored-dirs-aware,
  symlinks not followed). Actions/commands/tabs come from `CommandPalette.Actions`,
  a fixed allowlist. The palette **never** synthesises a free-form command
  — selecting a result dispatches one of the existing gated LiveView events.
  """

  alias DevIDE.CommandPalette.{Actions, FileIndex, Fuzzy, Item, Usage}

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
    usage = Keyword.get(opts, :usage, %{})
    now = Keyword.get(opts, :now)

    # Skip the FileIndex scan entirely when a non-file category is selected.
    file_items =
      if is_binary(root) and category in [:all, :files], do: file_items(root, q), else: []

    action_items = action_items(q)

    # Frecency must land before the sort + take: with an empty query every
    # item scores the flat base 1, so a post-truncation boost could never
    # promote an item the take already cut.
    (file_items ++ action_items)
    |> filter_by_category(category)
    |> apply_usage_boost(usage, now)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp apply_usage_boost(items, usage, %DateTime{} = now)
       when is_map(usage) and map_size(usage) > 0 do
    Enum.map(items, &%{&1 | score: &1.score + Usage.boost(usage[&1.id], now)})
  end

  defp apply_usage_boost(items, _usage, _now), do: items

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
          # Default open (Files-tab viewer) first; same score so stable sort
          # keeps the primary entry above the "open in pane" secondary.
          [
            %Item{
              id: "file:" <> rel,
              kind: :file,
              label: rel,
              detail: "Open file",
              score: s,
              payload: %{event: "annotation:open", params: %{"path" => rel}}
            },
            %Item{
              id: "file-pane:" <> rel,
              kind: :file,
              label: rel,
              detail: "Open in pane",
              keywords: ~w(pane split),
              score: s,
              payload: %{event: "tree:open_in_pane", params: %{"path" => rel}}
            }
          ]
      end
    end)
  end

  defp action_items(q) do
    Enum.flat_map(Actions.all(), fn item ->
      case action_score(item, q) do
        nil -> []
        s -> [%{item | score: s}]
      end
    end)
  end

  # Keywords are strictly a fallback for items whose label doesn't match at
  # all ("maximize" → Zoom): when the label matches, its score is used
  # unchanged so keyword strings can never reorder label-matched results.
  # Each keyword is scored individually — joining them would let a query
  # scatter-match across keyword boundaries ("spy" over "shell pty").
  defp action_score(%Item{label: label, keywords: keywords}, q) do
    Fuzzy.score(label, q) || keyword_score(keywords, q)
  end

  defp keyword_score([], _q), do: nil

  defp keyword_score(keywords, q) do
    keywords
    |> Enum.map(&Fuzzy.score(&1, q))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  @doc """
  Resolve an item id submitted from the wire back to its allowlisted payload.

  Returns `:error` if the id refers to nothing in the current allowlist or
  to a file that fails `PathSafety.resolve/2` against `root`.
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: {:ok, map()} | :error
  def resolve(_root, nil), do: :error

  # Path-derived file ids skip Actions.allowed_events/0 — they are not
  # static allowlist entries. Safety is PathSafety.resolve/2 against root.
  def resolve(root, "file-pane:" <> rel) when is_binary(root) and is_binary(rel) do
    case DevIDE.Files.PathSafety.resolve(root, rel) do
      {:ok, _} -> {:ok, %{event: "tree:open_in_pane", params: %{"path" => rel}}}
      _ -> :error
    end
  end

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
