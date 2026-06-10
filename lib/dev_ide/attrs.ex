defmodule DevIDE.Attrs do
  @moduledoc """
  Mixed-key map access for boundary payloads.

  Several contexts accept maps that may carry either string or atom keys:
  JSON request bodies decode to string keys, while internal callers pass
  atom-keyed maps. `get/2` looks up the string form first, then the
  existing-atom form.

  Safety: this module **never creates atoms**. `String.to_existing_atom/1`
  is used for the fallback lookup, so a hostile payload key cannot grow the
  atom table. (If the atom does not already exist, no map can be keyed by
  it, so returning `nil` is exact, not lossy.)
  """

  @doc """
  Fetch `key` (a string) from `map`, trying the string key first and the
  corresponding existing atom key second.

  Mirrors the `Map.get(map, key) || Map.get(map, atom_key)` pattern this
  helper replaced: a `nil`/`false` value under the string key falls through
  to the atom-key lookup.
  """
  @spec get(map(), String.t()) :: term()
  def get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || atom_key_value(map, key)
  end

  def get(_map, _key), do: nil

  defp atom_key_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
