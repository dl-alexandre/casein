defmodule DevIDE.Fleet.AssignmentRequirements do
  @moduledoc """
  Placement constraints for an assignment.

  These are attached to an assignment when it enters the fleet queue
  and consumed by `DevIDE.Fleet.Placement` to compute eligible runners.

  ## Design principle

  Placement must be **reproducible**: identical `AssignmentRequirements`
  + identical fleet snapshot must produce the same result every time.
  No hidden state, no heuristics, no randomness.

  ## Fields

    * `:capabilities` — required runner tags (all must match)
    * `:workspace_affinity` — prefer runners already holding this workspace
    * `:concurrency_group` — limit parallel assignments in this group
    * `:concurrency_limit` — maximum active assignments in the concurrency group
    * `:runner_pool` — optional logical pool, matched by metadata or capability
    * `:isolation` — `:shared` (default), `:dedicated` (exclusive runner)
    * `:priority` — `:low`, `:normal` (default), `:high`
    * `:anti_affinity` — runner IDs to avoid
    * `:max_runtime_ms` — execution timeout hint (not enforced by placement)
  """

  @type priority :: :low | :normal | :high
  @type isolation :: :shared | :dedicated

  @type t :: %__MODULE__{
          capabilities: [String.t()],
          workspace_affinity: String.t() | nil,
          concurrency_group: String.t() | nil,
          concurrency_limit: pos_integer() | nil,
          runner_pool: String.t() | nil,
          isolation: isolation(),
          priority: priority(),
          anti_affinity: [String.t()],
          max_runtime_ms: pos_integer() | nil
        }

  defstruct [
    :workspace_affinity,
    :concurrency_group,
    :concurrency_limit,
    :runner_pool,
    :max_runtime_ms,
    capabilities: [],
    isolation: :shared,
    priority: :normal,
    anti_affinity: []
  ]

  @doc "Create requirements from a keyword list or map."
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: struct!(__MODULE__, Map.new(attrs))
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)
end
