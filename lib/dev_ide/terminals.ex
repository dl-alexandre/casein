defmodule DevIDE.Terminals do
  @moduledoc """
  Public API for terminal sessions.

  Jx ownership goal:
  - This module (and submodules under DevIDE.Terminals) will become the single
    place for session identity, creation, attachment, and state.
  - The web layer (LiveViews and Channels) will only call into this API.
  """

  alias DevIDE.Terminals.{Attachment, SessionRegistry}
  alias DevIDE.Terminals.Session.Info

  defdelegate new_shell(workspace_id, sid, opts \\ []), to: Info
  defdelegate new_execution(execution_id, tmux_session, opts \\ []), to: Info
  defdelegate governed_by_default?(info), to: Info

  @doc "Lists all attachable terminal sessions for a workspace."
  @spec list_attachable(String.t()) :: [Info.t()]
  def list_attachable(workspace_id) do
    SessionRegistry.list_attachable(workspace_id)
  end

  @doc "Resolves a session identifier into session information."
  @spec resolve(String.t()) :: {:ok, Info.t()} | :error
  def resolve(sid) do
    SessionRegistry.resolve(sid)
  end

  @doc "Prepares attachment data for a given session id."
  @spec prepare_attachment(String.t()) :: {:ok, Info.t()} | :error
  def prepare_attachment(sid) do
    resolve(sid)
  end

  @doc """
  Determines the effective attachment mode for a session given the requested mode.

  Fleet executions always run in governed mode (the tmux session belongs to the
  runner, not the operator). Shells honor the requested mode.
  """
  @spec attachment_policy(Info.t(), :governed | :raw) :: {:ok, :governed | :raw}
  def attachment_policy(%Info{kind: :execution}, _requested), do: {:ok, :governed}
  def attachment_policy(%Info{kind: :shell}, requested), do: {:ok, requested}

  @doc "Opens a unified attachment handle for the given session."
  @spec attach(Info.t(), keyword()) :: {:ok, Attachment.t()} | {:error, term()}
  defdelegate attach(info, opts), to: Attachment, as: :open

  @doc "Starts a streamer process for an existing fleet tmux session."
  @spec start_execution_streamer(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_execution_streamer(tmux_session, subscriber) do
    DynamicSupervisor.start_child(
      DevIDE.Terminals.Supervisor,
      {DevIDE.Terminals.FleetSessionStreamer,
       [tmux_session: tmux_session, subscriber: subscriber]}
    )
  end
end
