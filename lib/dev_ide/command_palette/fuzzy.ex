defmodule DevIDE.CommandPalette.Fuzzy do
  @moduledoc """
  Cheap fuzzy scorer.

  Tiers (highest first):
    1. exact (case-insensitive) match — `1_000_000`
    2. target starts with query     — `500_000 - position_of_first_char`
    3. contiguous substring match   — `200_000 - position`
    4. acronym/scattered match      — `count_of_matched_chars * 100`
    5. no match                     — `nil`

  Ties broken by shorter target winning. Empty query returns base score so
  the caller can fall back to alphabetical ordering.
  """

  @spec score(String.t(), String.t()) :: integer() | nil
  def score(target, "") when is_binary(target), do: 1
  def score("", _), do: nil

  def score(target, query) when is_binary(target) and is_binary(query) do
    t = String.downcase(target)
    q = String.downcase(query)

    cond do
      t == q -> 1_000_000 + length_bonus(target)
      String.starts_with?(t, q) -> 500_000 - 0 + length_bonus(target)
      true -> substring_or_scattered(t, q, target)
    end
  end

  def score(_, _), do: nil

  defp substring_or_scattered(t, q, target) do
    case :binary.match(t, q) do
      {pos, _} -> 200_000 - pos + length_bonus(target)
      :nomatch -> scattered(t, q, target)
    end
  end

  defp scattered(t, q, target) do
    case scattered_count(String.graphemes(t), String.graphemes(q), 0) do
      0 -> nil
      n -> n * 100 + length_bonus(target)
    end
  end

  defp scattered_count(_, [], n), do: n
  defp scattered_count([], _q, _n), do: 0

  defp scattered_count([h | rest_t], [h | rest_q], n),
    do: scattered_count(rest_t, rest_q, n + 1)

  defp scattered_count([_ | rest_t], q, n), do: scattered_count(rest_t, q, n)

  # Shorter targets get a small bonus so e.g. "lib/a.ex" beats "lib/longer/a.ex"
  defp length_bonus(target) do
    max(0, 200 - byte_size(target))
  end
end
