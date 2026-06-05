defmodule DevIDE.Policy.Decision do
  @moduledoc """
  Outcome of a policy check. `mode` is the workspace mode at decision time so
  audit records carry both the verdict and the policy that produced it.
  """

  @type verdict :: :allow | :deny
  @type reason ::
          nil
          | :not_implemented
          | :agent_write_locked
          | :shared_stage_guarded
          | :unsafe_db
          | :requires_not_met
          | :not_allowed
          | :no_root
          | :too_large
          | :binary
          | :outside_root
          | :unknown_action
          | :requires_local_host
          | :requires_manual_mode
          | :forbidden
          | :config_override

  @type t :: %__MODULE__{
          action: atom(),
          verdict: verdict(),
          reason: reason(),
          mode: atom(),
          metadata: map()
        }

  @enforce_keys [:action, :verdict, :mode]
  defstruct [:action, :verdict, :reason, :mode, metadata: %{}]

  def allow(action, mode, metadata \\ %{}),
    do: %__MODULE__{action: action, verdict: :allow, reason: nil, mode: mode, metadata: metadata}

  def deny(action, mode, reason, metadata \\ %{}),
    do: %__MODULE__{
      action: action,
      verdict: :deny,
      reason: reason,
      mode: mode,
      metadata: metadata
    }

  def allow?(%__MODULE__{verdict: :allow}), do: true
  def allow?(_), do: false
end
