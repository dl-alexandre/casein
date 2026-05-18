defmodule DevIDE.Terminals do
  @moduledoc """
  Public API for terminal sessions.

  Jx ownership goal:
  - This module (and submodules under DevIDE.Terminals) will become the single
    place for session identity, creation, attachment, and state.
  - The web layer (LiveViews and Channels) will only call into this API.
  """

  alias DevIDE.Terminals.{Attachment, SessionOwner, SessionRegistry}
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

  @doc "Attaches a terminal owner for one logical session and subscribes the caller."
  @spec owner_attach(String.t(), Info.t(), keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def owner_attach(workspace_id, %Info{} = info, opts) when is_binary(workspace_id) do
    SessionOwner.attach(workspace_id, info, opts)
  end

  @doc "Detaches a caller from a terminal owner."
  @spec owner_detach(pid(), pid()) :: :ok | {:error, term()}
  def owner_detach(owner_pid, subscriber) when is_pid(owner_pid) and is_pid(subscriber) do
    if Process.alive?(owner_pid) do
      try do
        SessionOwner.detach(owner_pid, subscriber)
      rescue
        e in [ArgumentError] -> {:error, e}
      catch
        :exit, {:noproc, _} -> :ok
      end
    else
      :ok
    end
  end

  @doc "Sends raw terminal input through the terminal owner."
  @spec owner_input(pid(), binary()) :: :ok
  def owner_input(owner_pid, data) when is_pid(owner_pid) and is_binary(data) do
    SessionOwner.input(owner_pid, data)
  end

  @doc "Resizes terminal viewport through the terminal owner."
  @spec owner_resize(pid(), integer(), integer()) :: :ok
  def owner_resize(owner_pid, cols, rows) when is_integer(cols) and is_integer(rows) do
    SessionOwner.resize(owner_pid, cols, rows)
  end
end
