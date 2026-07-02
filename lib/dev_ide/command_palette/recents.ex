defmodule DevIDE.CommandPalette.Recents do
  @moduledoc """
  Per-workspace MRU of executed palette item ids.

  Backs the palette's recency boost: items the operator recently ran float to
  the top of the empty-query list and win ties while typing. In-memory only
  (public ETS owned by this server, shared across LiveView sessions) — history
  resets on node restart, which is acceptable for a ranking hint.

  Ids are only ever used as ranking keys; execution still goes through
  `CommandPalette.resolve/2` and the event allowlist, so a stale or bogus id
  here can influence ordering but never dispatch anything.
  """

  use GenServer

  @table :dev_ide_palette_recents
  @cap 15

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record `item_id` as the most recent execution for `workspace_id`."
  @spec record(String.t(), String.t()) :: :ok
  def record(workspace_id, item_id) when is_binary(workspace_id) and is_binary(item_id) do
    if table_ready?() do
      ids = Enum.take([item_id | List.delete(list(workspace_id), item_id)], @cap)
      :ets.insert(@table, {workspace_id, ids})
    end

    :ok
  end

  def record(_, _), do: :ok

  @doc "Most-recent-first executed item ids for `workspace_id`."
  @spec list(String.t()) :: [String.t()]
  def list(workspace_id) when is_binary(workspace_id) do
    with true <- table_ready?(),
         [{^workspace_id, ids}] <- :ets.lookup(@table, workspace_id) do
      ids
    else
      _ -> []
    end
  end

  def list(_), do: []

  @doc "Map of item id → 0-based recency rank (0 = most recent)."
  @spec ranks(String.t()) :: %{String.t() => non_neg_integer()}
  def ranks(workspace_id) do
    workspace_id |> list() |> Enum.with_index() |> Map.new()
  end

  def cap, do: @cap

  defp table_ready?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
