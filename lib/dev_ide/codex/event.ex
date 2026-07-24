defmodule Casein.Codex.Event do
  @moduledoc """
  Stable, transport-independent events emitted by Codex integrations.

  App Server JSON-RPC, non-interactive JSONL, and CLI hooks must normalize into
  this contract before their data reaches the rest of Casein. The runtime-local
  `sequence` preserves receive order; `occurred_at` is the UTC wall-clock value
  used for persistence and display.
  """

  @schema_version 1
  @transports [:app_server, :exec, :hook, :notify]
  @types [
    :thread_started,
    :thread_status_changed,
    :turn_started,
    :turn_failed,
    :item_started,
    :item_completed,
    :agent_message_delta,
    :turn_completed,
    :usage_updated,
    :approval_requested,
    :approval_resolved,
    :subagent_started,
    :subagent_stopped,
    :hook_observed,
    :error
  ]

  @enforce_keys [
    :id,
    :type,
    :workspace_id,
    :runtime_id,
    :transport,
    :sequence,
    :occurred_at,
    :payload,
    :metadata
  ]
  defstruct [
    :id,
    :type,
    :workspace_id,
    :runtime_id,
    :transport,
    :sequence,
    :occurred_at,
    :thread_id,
    :parent_thread_id,
    :session_id,
    :turn_id,
    :item_id,
    :tool_call_id,
    :request_id,
    :payload,
    :metadata,
    schema_version: @schema_version
  ]

  @type transport :: :app_server | :exec | :hook | :notify
  @type event_type ::
          :thread_started
          | :thread_status_changed
          | :turn_started
          | :turn_failed
          | :item_started
          | :item_completed
          | :agent_message_delta
          | :turn_completed
          | :usage_updated
          | :approval_requested
          | :approval_resolved
          | :subagent_started
          | :subagent_stopped
          | :hook_observed
          | :error

  @type t :: %__MODULE__{
          id: String.t(),
          schema_version: pos_integer(),
          type: event_type(),
          workspace_id: String.t(),
          runtime_id: String.t(),
          transport: transport(),
          sequence: pos_integer(),
          occurred_at: DateTime.t(),
          thread_id: String.t() | nil,
          parent_thread_id: String.t() | nil,
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          item_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          request_id: String.t() | integer() | nil,
          payload: map(),
          metadata: map()
        }

  @doc "Build a validated canonical event from trusted normalization context."
  @spec new!(event_type(), map(), keyword()) :: t()
  def new!(type, context, attrs \\ []) when is_map(context) and is_list(attrs) do
    event = %__MODULE__{
      id: Keyword.get_lazy(attrs, :id, &Ecto.UUID.generate/0),
      type: type,
      workspace_id: Map.get(context, :workspace_id),
      runtime_id: Map.get(context, :runtime_id),
      transport: Map.get(context, :transport),
      sequence: Map.get(context, :sequence),
      occurred_at: Map.get(context, :occurred_at, DateTime.utc_now()),
      thread_id: Keyword.get(attrs, :thread_id),
      parent_thread_id: Keyword.get(attrs, :parent_thread_id),
      session_id: Keyword.get(attrs, :session_id),
      turn_id: Keyword.get(attrs, :turn_id),
      item_id: Keyword.get(attrs, :item_id),
      tool_call_id: Keyword.get(attrs, :tool_call_id),
      request_id: Keyword.get(attrs, :request_id),
      payload: Keyword.get(attrs, :payload, %{}),
      metadata: Keyword.get(attrs, :metadata, %{})
    }

    validate!(event)
  end

  @doc false
  @spec resequence(t(), pos_integer()) :: t()
  def resequence(%__MODULE__{} = event, sequence)
      when is_integer(sequence) and sequence > 0 do
    %{event | sequence: sequence}
  end

  defp validate!(%__MODULE__{} = event) do
    true = event.type in @types
    true = event.transport in @transports
    true = present_string?(event.id)
    true = present_string?(event.workspace_id)
    true = present_string?(event.runtime_id)
    true = is_integer(event.sequence) and event.sequence > 0
    true = is_struct(event.occurred_at, DateTime)
    true = is_map(event.payload)
    true = is_map(event.metadata)
    event
  rescue
    _error in MatchError ->
      reraise ArgumentError, [message: "invalid canonical Codex event"], __STACKTRACE__
  end

  defp present_string?(value), do: is_binary(value) and value != ""
end
