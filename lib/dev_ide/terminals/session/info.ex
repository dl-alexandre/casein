defmodule DevIDE.Terminals.Session.Info do
  @moduledoc """
  Unified data structure representing any terminal session.

  Workspace shells and agent-driven sessions are represented uniformly through
  this type.
  """

  @type kind :: :shell | :agent
  @type status :: :active | :exited | :error
  @type loc :: :local | :remote

  defstruct [
    :id,
    :kind,
    :workspace_id,
    :sid,
    :tmux_session,
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

  @doc """
  Builds a Session.Info for an agent-driven session.

  The attachment pipeline accepts this kind as a read-only session.
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
end
