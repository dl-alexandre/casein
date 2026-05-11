defmodule DevIDE.Runners.Assignment do
  @moduledoc "Durable runner assignment claimed through the JX runner protocol."

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          workspace_id: String.t(),
          safe_action_id: String.t(),
          safe_action_version: pos_integer(),
          status: status(),
          requested_by: String.t() | nil,
          claimed_by: String.t() | nil,
          claim_token: String.t() | nil,
          queued_at: DateTime.t() | nil,
          claimed_at: DateTime.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          failure_reason: String.t() | nil,
          evidence: map(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :workspace_id, :safe_action_id, :safe_action_version, :status, :queued_at]
  defstruct [
    :id,
    :workspace_id,
    :safe_action_id,
    :safe_action_version,
    :status,
    :requested_by,
    :claimed_by,
    :claim_token,
    :queued_at,
    :claimed_at,
    :lease_expires_at,
    :completed_at,
    :failure_reason,
    :inserted_at,
    :updated_at,
    evidence: %{},
    metadata: %{}
  ]
end
