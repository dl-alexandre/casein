defmodule DevIDE.UAT.Matcher do
  @moduledoc """
  Resolves a frozen `DevIDE.UAT.Step` `match` against the *live* element list
  from `preview_elements`, re-deriving the element a trace was authored against
  even though its positional `element_id` ("el_N") is long gone.

  Resolution order (narrowing only when still ambiguous):

    1. `selector` — the durable CSS selector frozen at author time
    2. `role` — narrow when the selector matches more than one element
    3. `name` — narrow further
    4. `nth` — pick a specific match when several remain

  `near_text` is accepted in a match but not yet used: `preview_elements` does
  not carry surrounding text, so it is reserved for a future summarizer field.

  Returns `{:ok, element}`, `{:error, :no_match}` (the frozen target is gone —
  the caller treats this as *drift*), or `{:error, :ambiguous}` (several live
  elements match and no `nth` disambiguates them).
  """

  @type element :: map()
  @type match :: map()

  @spec resolve([element()], match()) ::
          {:ok, element()} | {:error, :no_match | :ambiguous}
  def resolve(elements, match) when is_list(elements) and is_map(match) do
    elements
    |> filter_present(match, "selector", :selector)
    |> narrow_if_ambiguous(match, "role", :role)
    |> narrow_if_ambiguous(match, "name", :name)
    |> pick(get(match, "nth"))
  end

  # Always filter on selector when the match provides one.
  defp filter_present(elements, match, key, field) do
    case get(match, key) do
      nil -> elements
      value -> Enum.filter(elements, &(field(&1, field) == value))
    end
  end

  # Narrow on role/name only when more than one candidate survives.
  defp narrow_if_ambiguous([_single] = elements, _match, _key, _field), do: elements

  defp narrow_if_ambiguous(elements, match, key, field) do
    case get(match, key) do
      nil -> elements
      value -> Enum.filter(elements, &(field(&1, field) == value))
    end
  end

  defp pick([element], _nth), do: {:ok, element}
  defp pick([], _nth), do: {:error, :no_match}

  defp pick(elements, nth) when is_integer(nth) do
    case Enum.at(elements, nth) do
      nil -> {:error, :no_match}
      element -> {:ok, element}
    end
  end

  defp pick(_elements, _nth), do: {:error, :ambiguous}

  # Element maps come from PreviewTools with atom keys; tolerate string keys too.
  defp field(element, field) do
    Map.get(element, field) || Map.get(element, Atom.to_string(field))
  end

  # Match maps come from JSON with string keys; tolerate atom keys too.
  defp get(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> atom_get(map, key)
    end
  end

  defp atom_get(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    # No atom variant was ever defined → the key is simply absent.
    ArgumentError -> nil
  end
end
