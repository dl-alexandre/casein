defmodule DevIDE.Terminals.Session.Info do
  @moduledoc """
  Unified data structure representing any terminal session (Phase 2+).

  This struct is the foundation for Jx owning all terminal sessions.
  Both local workspace shells and fleet execution tmux sessions are
  represented uniformly through this type.
  """

  @type kind :: :shell | :execution | :agent
  @type status :: :active | :exited | :error
  @type loc :: :local | :remote

  defstruct [
    :id,
    :kind,
    :workspace_id,
    :sid,
    :tmux_session,
    :execution_id,
    :runner_id,
    loc: :local,
    status: :active,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          workspace_id: String.t() | nil,
          sid: String.t() | nil,
          tmux_session: String.t() | nil,
          execution_id: String.t() | nil,
          runner_id: String.t() | nil,
          loc: loc(),
          status: status(),
          metadata: map()
        }

  @doc "Builds a Session.Info for a workspace shell."
  def new_shell(workspace_id, sid, opts \\ []) do
    %__MODULE__{
      id: "shell_#{workspace_id}_#{sid}",
      kind: :shell,
      workspace_id: workspace_id,
      sid: sid,
      status: Keyword.get(opts, :status, :active),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Builds a Session.Info for a fleet execution."
  def new_execution(execution_id, tmux_session, opts \\ []) do
    %__MODULE__{
      id: "exec_#{execution_id}",
      kind: :execution,
      workspace_id: Keyword.get(opts, :workspace_id),
      execution_id: execution_id,
      tmux_session: tmux_session,
      runner_id: Keyword.get(opts, :runner_id),
      loc: Keyword.get(opts, :loc, :local),
      status: Keyword.get(opts, :status, :active),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Builds a Session.Info for an agent-driven session.

  Phase 3 groundwork: the attachment pipeline must accept this kind even though
  no agent backend exists yet. Callers should treat `:agent` like a read-only
  execution until the backend lands.
  """
  def new_agent(agent_id, opts \\ []) do
    %__MODULE__{
      id: "agent_#{agent_id}",
      kind: :agent,
      workspace_id: Keyword.get(opts, :workspace_id),
      runner_id: Keyword.get(opts, :runner_id),
      loc: Keyword.get(opts, :loc, :local),
      status: Keyword.get(opts, :status, :active),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Fleet and remote sessions default to governed mode for safety.

  Remote shells (kind: :shell, loc: :remote) also default to governed — the
  cockpit may not have direct PTY reach to the remote host, and the runner
  protocol is the only safe ingress.
  """
  def governed_by_default?(%__MODULE__{kind: :execution}), do: true
  def governed_by_default?(%__MODULE__{kind: :agent}), do: true
  def governed_by_default?(%__MODULE__{loc: :remote}), do: true
  def governed_by_default?(_), do: false
end
