defmodule Casein.UAT.Trace do
  @moduledoc """
  A frozen UAT trace: the durable, version-controlled definition of one
  user-acceptance scenario. Authored once by the acceptance agent (driving the
  `preview_*` MCP tools), then replayed deterministically with no LLM.

  A trace is stored as `priv/uat/<scenario>/trace.json` so it is reviewable and
  git-diffable — the self-heal flow proposes changes as a PR diff against this
  file, never an in-place mutation.

  ## Why steps store selectors, not `element_id`

  `element_id` ("el_N") from `preview_elements` is a *positional index into the
  observation that produced it* — it is not stable across sessions or markup
  edits. A frozen `Casein.UAT.Step` therefore stores a durable `match`
  (selector + role/name + nth/near_text), which `Casein.UAT.Replay` re-resolves
  to a live `element_id` against a fresh `preview_elements` at replay time. The
  authoring `resolved_el` is kept under `from` for audit only — never a replay
  key.
  """

  alias Casein.UAT.Step

  @enforce_keys [:id, :criterion]
  defstruct id: nil,
            criterion: nil,
            target: %{},
            identity: nil,
            provenance: %{},
            steps: [],
            baselines: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          criterion: String.t(),
          target: map(),
          identity: String.t() | nil,
          provenance: map(),
          steps: [Step.t()],
          baselines: map()
        }

  @doc """
  Build a plain, JSON-encodable map from a trace. The inverse of `from_map/1`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = trace) do
    %{
      "id" => trace.id,
      "criterion" => trace.criterion,
      "target" => stringify(trace.target),
      "identity" => trace.identity,
      "provenance" => stringify(trace.provenance),
      "steps" => Enum.map(trace.steps, &Step.to_map/1),
      "baselines" => stringify(trace.baselines)
    }
  end

  @doc """
  Parse a decoded JSON map (string keys) into a `%Trace{}`. Unknown step kinds
  raise `ArgumentError` rather than minting atoms, so a malformed file fails
  loudly at load time instead of at replay.
  """
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      id: fetch!(map, "id"),
      criterion: fetch!(map, "criterion"),
      target: Map.get(map, "target", %{}),
      identity: Map.get(map, "identity"),
      provenance: Map.get(map, "provenance", %{}),
      steps: map |> Map.get("steps", []) |> Enum.map(&Step.from_map/1),
      baselines: Map.get(map, "baselines", %{})
    }
  end

  @doc "Encode a trace as pretty JSON for writing to `priv/uat/<scenario>/trace.json`."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = trace) do
    trace |> to_map() |> Jason.encode!(pretty: true)
  end

  @doc "Decode a trace from JSON text. Raises on malformed JSON or unknown step kinds."
  @spec from_json(String.t()) :: t()
  def from_json(json) when is_binary(json) do
    json |> Jason.decode!() |> from_map()
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when value not in [nil, ""] -> value
      _ -> raise ArgumentError, "trace is missing required field #{inspect(key)}"
    end
  end

  # Recursively coerce atom keys to strings so a struct built in Elixir and one
  # loaded from JSON serialize identically (round-trip stability).
  defp stringify(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
