defmodule DevIDE.Fleet.Notification do
  @moduledoc """
  Canonical shape for fleet topology change notifications.

  Broadcast **after** the registry mutation is committed.
  Subscribers receive this, not raw protocol messages, so every
  consumer sees the same derived fleet state.

  ## Topics

    * `"fleet:runners"` — runner registration, heartbeat, state changes
    * `"fleet:leases"` — lease acquisition, release, expiry, revoke
    * `"fleet:executions"` — execution state transitions
    * `"fleet:output"` — observational chunks (stdout, stderr, telemetry)
    * `"fleet:assignments:{assignment_id}"` — scoped assignment execution events

  Do not treat PubSub as a source of truth — the fleet registry and
  assignment event stream remain the durable authority.  Subscriptions
  are ephemeral views.
  """

  @type kind ::
          :runner_registered
          | :runner_heartbeat
          | :runner_offline
          | :lease_acquired
          | :lease_released
          | :lease_expired
          | :lease_renewed
          | :lease_revoked
          | :execution_started
          | :execution_completed
          | :execution_failed
          | :execution_abandoned
          | :output_chunk
          | :telemetry

  @type t :: %__MODULE__{
          kind: kind(),
          assignment_id: String.t() | nil,
          runner_id: String.t() | nil,
          lease_id: String.t() | nil,
          execution_id: String.t() | nil,
          payload: map(),
          occurred_at: DateTime.t()
        }

  defstruct [
    :kind,
    :assignment_id,
    :runner_id,
    :lease_id,
    :execution_id,
    :payload,
    :occurred_at
  ]
end
