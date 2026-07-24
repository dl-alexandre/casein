defmodule Casein.CommandPalette.Usage do
  @moduledoc """
  Per-workspace palette execution history ("frecency").

  Every successfully resolved `palette:execute` records `{workspace_id,
  item_id}` here; `PaletteItems.query/2` folds the counts back into result
  ranking so recently/frequently used items surface first. Recording is
  fire-and-forget: a storage failure must never break the execution it
  annotates, so `record/2` rescues and logs instead of raising.
  """

  import Ecto.Query

  require Logger

  alias Casein.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "palette_usage" do
      field :workspace_id, :string
      field :item_id, :string
      field :uses, :integer, default: 1
      field :last_used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end

  # Both calls run synchronously on the LiveView process; a short timeout
  # bounds the stall under DB contention (the rescue keeps failures silent).
  @db_timeout 2_000

  @doc "Record one execution of `item_id` in `workspace_id` (upsert increment)."
  @spec record(String.t(), String.t()) :: :ok
  def record(workspace_id, item_id)
      when is_binary(workspace_id) and is_binary(item_id) and item_id != "" do
    now = DateTime.utc_now()

    %Row{workspace_id: workspace_id, item_id: item_id, uses: 1, last_used_at: now}
    |> Repo.insert(
      on_conflict: [inc: [uses: 1], set: [last_used_at: now, updated_at: now]],
      conflict_target: [:workspace_id, :item_id],
      timeout: @db_timeout
    )

    :ok
  rescue
    error ->
      Logger.warning("palette usage record failed: #{Exception.message(error)}")
      :ok
  end

  def record(_workspace_id, _item_id), do: :ok

  @doc """
  Frecency boost for one usage entry (`nil` → 0).

  Capped at 750: min(uses, 20) * 25 (≤ 500) plus a recency bonus of
  250/125/50 for < 1h / < 24h / < 7d. The cap keeps habit strictly below
  every context boost in `PaletteItems` — window-active panes (+800),
  focused pane (+1,200), return-to-shell (+1,800), active session
  (+2,000) — while still dominating the flat empty-query base score of 1
  and reordering near-ties inside a typed-query fuzzy tier.
  """
  @spec boost(map() | nil, DateTime.t()) :: non_neg_integer()
  def boost(nil, _now), do: 0

  def boost(%{uses: uses, last_used_at: last_used_at}, %DateTime{} = now) do
    min(uses, 20) * 25 + recency_bonus(last_used_at, now)
  end

  defp recency_bonus(%DateTime{} = last_used_at, now) do
    age = DateTime.diff(now, last_used_at, :second)

    cond do
      age < 3_600 -> 250
      age < 86_400 -> 125
      age < 604_800 -> 50
      true -> 0
    end
  end

  defp recency_bonus(_last_used_at, _now), do: 0

  @doc """
  Usage map for ranking: `%{item_id => %{uses: n, last_used_at: dt}}`.

  Capped at the most recently used `limit` rows — stale one-off entries age
  out of the ranking window instead of accumulating forever.
  """
  @spec for_workspace(String.t(), pos_integer()) :: %{String.t() => map()}
  def for_workspace(workspace_id, limit \\ 200) when is_binary(workspace_id) do
    Row
    |> where([r], r.workspace_id == ^workspace_id)
    |> order_by([r], desc: r.last_used_at)
    |> limit(^limit)
    |> select([r], {r.item_id, %{uses: r.uses, last_used_at: r.last_used_at}})
    |> Repo.all(timeout: @db_timeout)
    |> Map.new()
  rescue
    error ->
      Logger.warning("palette usage load failed: #{Exception.message(error)}")
      %{}
  end
end
