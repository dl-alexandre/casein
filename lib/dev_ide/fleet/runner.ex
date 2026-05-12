defmodule DevIDE.Fleet.Runner do
  @moduledoc """
  A physical runner in the fleet topology.

  Distinct from `DevIDE.Runners.Assignment` (the JX wire-protocol struct).
  This represents a runner *node* — a machine, container, or process
  that can execute assignments.

  ## States

    * `:registering` — initial registration, not yet heartbeated
    * `:online` — actively heartbeating, ready for work
    * `:idle` — online but has no active lease
    * `:busy` — online and currently executing an assignment
    * `:offline` — heartbeat missed, likely disconnected
    * `:stale` — offline for extended period, may need cleanup
    * `:draining` — marked for shutdown, no new leases accepted
    * `:maintenance` — intentionally paused for operator maintenance

  ## Capabilities

  Free-form tags the runner advertises at registration:

    * `"gpu"` — has GPU access
    * `"docker"` — can run Docker containers
    * `"linux"`, `"macos"`, `"windows"` — OS family
    * `"self-hosted"` — not ephemeral/cloud
    * `"repo:<name>"` — has specific repo checked out
  """

  @type state ::
          :registering | :online | :idle | :busy | :offline | :stale | :draining | :maintenance

  @type t :: %__MODULE__{
          id: String.t(),
          hostname: String.t(),
          capabilities: [String.t()],
          state: state(),
          active_assignment_id: String.t() | nil,
          last_heartbeat_at: DateTime.t() | nil,
          registered_at: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:id, :hostname]
  defstruct [
    :id,
    :hostname,
    :capabilities,
    :state,
    :active_assignment_id,
    :last_heartbeat_at,
    :registered_at,
    metadata: %{}
  ]
end
