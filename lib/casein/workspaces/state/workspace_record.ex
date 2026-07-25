defmodule Casein.Workspaces.State.WorkspaceRecord do
  @moduledoc """
  Domain struct for a persisted workspace cache entry.

  Manager remains the authority for lifecycle (`create/start/stop/delete`).
  This record captures **what the IDE has observed** — last manager payload,
  resolved mode, and the latest redacted DB isolation snapshot — so the UI
  has something to show before the next live probe completes.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          external_id: String.t(),
          name: String.t(),
          user: String.t() | nil,
          host_path: String.t() | nil,
          status: String.t() | nil,
          mode: String.t() | nil,
          db_isolation: String.t() | nil,
          db_isolation_source: String.t() | nil,
          db_isolation_summary: String.t() | nil,
          db_isolation_detected_at: DateTime.t() | nil,
          manager_payload: map(),
          last_seen_at: DateTime.t() | nil,
          agent_write_unlocked_until: DateTime.t() | nil,
          agent_write_unlocked_by: String.t() | nil,
          agent_write_unlock_granted_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :external_id,
    :name,
    :user,
    :host_path,
    :status,
    :mode,
    :db_isolation,
    :db_isolation_source,
    :db_isolation_summary,
    :db_isolation_detected_at,
    :last_seen_at,
    :agent_write_unlocked_until,
    :agent_write_unlocked_by,
    :agent_write_unlock_granted_at,
    :inserted_at,
    :updated_at,
    manager_payload: %{}
  ]

  @stale_status "stale"

  @doc """
  Status marking a record the workspace source no longer vouches for.

  Written by `Casein.Workspaces.Reconciler` and filtered out of the sidebar by
  `CaseinWeb.WorkspaceLive.Show.CockpitData`. A record retired this way is kept,
  not deleted: it still carries the IDE-owned mode and isolation history, and a
  workspace recreated under the same id resyncs back to a live status.
  """
  @spec stale_status() :: String.t()
  def stale_status, do: @stale_status

  @doc "True when the source has stopped vouching for this record."
  @spec retired?(t()) :: boolean()
  def retired?(%__MODULE__{status: @stale_status}), do: true
  def retired?(%__MODULE__{}), do: false

  @doc """
  Picks the canonical record when several share a `host_path`: a manager
  identity (non-`folder:` external_id) wins over a path-derived one, then
  the most recently seen.
  """
  @spec preferred([t()]) :: t() | nil
  def preferred([]), do: nil

  def preferred(records) when is_list(records) do
    Enum.min_by(records, fn r -> {folder_id?(r.external_id), seen_rank(r)} end)
  end

  defp folder_id?("folder:" <> _rest), do: true
  defp folder_id?(_), do: false

  # Negated epoch so more recent sorts first; records never seen rank last.
  defp seen_rank(%__MODULE__{last_seen_at: %DateTime{} = at}),
    do: -DateTime.to_unix(at, :microsecond)

  defp seen_rank(_record), do: 0
end
