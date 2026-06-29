defmodule DevIDE.UAT.Step do
  @moduledoc """
  One step of a frozen `DevIDE.UAT.Trace` — either an action to perform or an
  assertion to evaluate during replay.

  Kinds:

    * `:navigate`         — `path` (URL or path)
    * `:click`            — `match` (durable element matcher)
    * `:type`             — `match` + `text`
    * `:press`            — `key`
    * `:assert_element`   — `match` + `presence` (true = must be present)
    * `:assert_url`       — `matches` (substring/pattern the current URL must satisfy)
    * `:assert_no_errors` — `console` / `network` (booleans, which error classes to check)

  `match` is a durable matcher map (`selector`, `role`, `name`, `nth`,
  `near_text`) — see `DevIDE.UAT.Trace` for why selectors are frozen instead of
  `element_id`. `from` records authoring provenance (`action_id`,
  `observation_id`, `resolved_el`) and is audit-only — never used to resolve a
  target at replay.
  """

  @kinds ~w(navigate click type press assert_element assert_url assert_no_errors)a
  @kind_strings Enum.map(@kinds, &Atom.to_string/1)

  @enforce_keys [:kind]
  defstruct kind: nil,
            match: nil,
            text: nil,
            key: nil,
            path: nil,
            matches: nil,
            presence: nil,
            console: nil,
            network: nil,
            from: %{}

  @type t :: %__MODULE__{
          kind: atom(),
          match: map() | nil,
          text: String.t() | nil,
          key: String.t() | nil,
          path: String.t() | nil,
          matches: String.t() | nil,
          presence: boolean() | nil,
          console: boolean() | nil,
          network: boolean() | nil,
          from: map()
        }

  @doc "The set of valid step kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Build a JSON-encodable map from a step, dropping nil fields for a clean diff."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = step) do
    %{
      "kind" => Atom.to_string(step.kind),
      "match" => step.match,
      "text" => step.text,
      "key" => step.key,
      "path" => step.path,
      "matches" => step.matches,
      "presence" => step.presence,
      "console" => step.console,
      "network" => step.network,
      "from" => step.from || %{}
    }
    |> Enum.reject(fn {key, value} -> value in [nil] and key != "from" end)
    |> Map.new()
  end

  @doc """
  Parse a decoded JSON map into a `%Step{}`. The `kind` is validated against the
  allowlist and converted with `String.to_existing_atom/1`, so a bad file can
  never mint an arbitrary atom.
  """
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      kind: parse_kind(Map.get(map, "kind")),
      match: Map.get(map, "match"),
      text: Map.get(map, "text"),
      key: Map.get(map, "key"),
      path: Map.get(map, "path"),
      matches: Map.get(map, "matches"),
      presence: Map.get(map, "presence"),
      console: Map.get(map, "console"),
      network: Map.get(map, "network"),
      from: Map.get(map, "from", %{})
    }
  end

  defp parse_kind(kind) when kind in @kind_strings, do: String.to_existing_atom(kind)

  defp parse_kind(kind) do
    raise ArgumentError,
          "unknown UAT step kind #{inspect(kind)} (expected one of #{inspect(@kind_strings)})"
  end
end
