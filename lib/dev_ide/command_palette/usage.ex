defmodule DevIDE.CommandPalette.Usage do
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

  alias DevIde.Repo

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

  @doc "Record one execution of `item_id` in `workspace_id` (upsert increment)."
  @spec record(String.t(), String.t()) :: :ok
  def record(workspace_id, item_id)
      when is_binary(workspace_id) and is_binary(item_id) and item_id != "" do
    now = DateTime.utc_now()

    %Row{workspace_id: workspace_id, item_id: item_id, uses: 1, last_used_at: now}
    |> Repo.insert(
      on_conflict: [inc: [uses: 1], set: [last_used_at: now, updated_at: now]],
      conflict_target: [:workspace_id, :item_id]
    )

    :ok
  rescue
    error ->
      Logger.warning("palette usage record failed: #{Exception.message(error)}")
      :ok
  end

  def record(_workspace_id, _item_id), do: :ok

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
    |> Repo.all()
    |> Map.new()
  rescue
    error ->
      Logger.warning("palette usage load failed: #{Exception.message(error)}")
      %{}
  end
end
