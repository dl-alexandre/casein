defmodule DevIDE.Fleet.Policy do
  @moduledoc """
  Deterministic placement policy.

  Chooses a single runner from the eligible list produced by
  `DevIDE.Fleet.Placement.compute_eligible/2`.

  ## Current policies

    * `:first` — choose the first eligible runner (default)
    * `:round_robin` — cycle through eligible runners (requires state)
    * `:least_loaded` — choose the runner with fewest active leases

  All policies are deterministic given the same eligible list.
  No randomness, no heuristics, no hidden state.
  """

  @type policy_type :: :first | :round_robin | :least_loaded

  @doc """
  Apply the configured policy to choose one runner from eligible candidates.

  Returns `nil` when the eligible list is empty.
  """
  @spec choose([String.t()], policy_type(), keyword()) :: String.t() | nil
  def choose(eligible, policy_type \\ :first, opts \\ [])

  def choose([], _, _), do: nil

  def choose([first | _], :first, _), do: first

  def choose(eligible, :round_robin, opts) do
    last_chosen = Keyword.get(opts, :last_chosen)

    case Enum.find_index(eligible, &(&1 == last_chosen)) do
      nil -> List.first(eligible)
      idx -> Enum.at(eligible, rem(idx + 1, length(eligible)), List.first(eligible))
    end
  end

  def choose(eligible, :least_loaded, opts) do
    load_map = Keyword.get(opts, :load_map, %{})

    eligible
    |> Enum.map(fn runner_id -> {runner_id, Map.get(load_map, runner_id, 0)} end)
    |> Enum.sort_by(fn {_, load} -> load end)
    |> List.first()
    |> then(fn
      nil -> List.first(eligible)
      {runner_id, _} -> runner_id
    end)
  end
end
