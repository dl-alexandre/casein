defmodule DevIDE.Workspaces.State.WorkspaceRecord do
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
end
