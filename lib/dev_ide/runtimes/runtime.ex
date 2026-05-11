defmodule DevIDE.Runtimes.Runtime do
  @moduledoc "Durable projection of a workspace execution environment."

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          workspace_id: String.t(),
          host_id: String.t(),
          os: String.t() | nil,
          repo: String.t() | nil,
          branch: String.t() | nil,
          worktree_path: String.t() | nil,
          runner_id: String.t() | nil,
          session_id: String.t() | nil,
          tmux_session_id: String.t() | nil,
          isolation_mode: String.t(),
          status: status(),
          capabilities: [String.t()],
          tools: [String.t()],
          concurrency_limit: pos_integer(),
          active_assignments: non_neg_integer(),
          created_at: DateTime.t() | nil,
          heartbeat_at: DateTime.t() | nil,
          expired_at: DateTime.t() | nil,
          cleaned_at: DateTime.t() | nil,
          failure_reason: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :workspace_id, :host_id, :isolation_mode, :status, :created_at]
  defstruct [
    :id,
    :workspace_id,
    :host_id,
    :os,
    :repo,
    :branch,
    :worktree_path,
    :runner_id,
    :session_id,
    :tmux_session_id,
    :isolation_mode,
    :status,
    :created_at,
    :heartbeat_at,
    :expired_at,
    :cleaned_at,
    :failure_reason,
    :inserted_at,
    :updated_at,
    capabilities: [],
    tools: [],
    concurrency_limit: 1,
    active_assignments: 0,
    metadata: %{}
  ]
end
