defmodule DevIDE.Codex.Approval do
  @moduledoc """
  Canonical representation of an App Server approval request.

  The struct deliberately keeps Codex method names and wire-only fields in
  metadata while exposing stable correlation fields to the broker and UI.
  """

  @enforce_keys [
    :id,
    :kind,
    :workspace_id,
    :runtime_id,
    :request_id,
    :thread_id,
    :turn_id,
    :item_id,
    :requested_at,
    :payload,
    :metadata
  ]
  defstruct [
    :id,
    :kind,
    :workspace_id,
    :runtime_id,
    :request_id,
    :thread_id,
    :turn_id,
    :item_id,
    :approval_id,
    :requested_at,
    :payload,
    :metadata,
    status: :pending,
    resolved_at: nil,
    resolution: nil
  ]

  @type kind :: :command_execution | :file_change | :permissions
  @type status :: :pending | :granted | :denied | :cancelled | :transport_failed

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          workspace_id: String.t(),
          runtime_id: String.t(),
          request_id: String.t() | integer(),
          thread_id: String.t(),
          turn_id: String.t(),
          item_id: String.t(),
          approval_id: String.t() | nil,
          requested_at: DateTime.t(),
          payload: map(),
          metadata: map(),
          status: status(),
          resolved_at: DateTime.t() | nil,
          resolution: atom() | map() | nil
        }
end
