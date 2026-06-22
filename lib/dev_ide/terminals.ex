defmodule DevIDE.Terminals do
  @moduledoc """
  Public API for terminal sessions.

  Jx ownership goal:
  - This module (and submodules under DevIDE.Terminals) will become the single
    place for session identity, creation, attachment, and state.
  - The web layer (LiveViews and Channels) will only call into this API.
  """
  require Logger

  alias DevIDE.Terminals.{
    Attachment,
    GhosttyRawAdapter,
    ModePolicy,
    SessionDirectory,
    SessionOwner,
    SessionRegistry
  }

  alias DevIDE.Terminals.Session.Info
  alias DevIDE.Terminals.SessionDirectory.Compose

  defdelegate new_shell(workspace_id, sid, opts \\ []), to: Info
  defdelegate new_agent(agent_id, opts \\ []), to: Info

  @doc "Lists all attachable terminal sessions for a workspace."
  @spec list_attachable(String.t()) :: [Info.t()]
  def list_attachable(workspace_id) do
    SessionRegistry.list_attachable(workspace_id)
  end

  @doc """
  Canonical session tab list for a workspace (live shells + scanned tmux
  sessions, deduplicated). Served by the per-workspace `SessionDirectory`;
  viewer-independent — apply `visible_tabs/2`.
  """
  @spec session_tabs(String.t(), keyword()) :: [Info.t()]
  defdelegate session_tabs(workspace_id, opts \\ []), to: SessionDirectory, as: :tabs

  @doc "Subscribes the caller to `{:sessions_updated, workspace_id, tabs}` broadcasts."
  @spec subscribe_session_tabs(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate subscribe_session_tabs(workspace_id, opts \\ []),
    to: SessionDirectory,
    as: :subscribe

  @doc "Applies the per-viewer staleness/default-shell filters to a tab list."
  @spec visible_tabs([Info.t()], String.t() | nil) :: [Info.t()]
  defdelegate visible_tabs(tabs, default_sid), to: Compose, as: :visible_for

  @doc "Ensures the viewer's landing session is present so the picker always shows a home row."
  @spec with_default_shell([Info.t()], String.t() | nil, String.t(), String.t()) :: [Info.t()]
  defdelegate with_default_shell(tabs, default_sid, workspace_id, workspace_name), to: Compose

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
  Determines the effective attachment mode for a session. Always `:raw`.
  """
  @spec attachment_policy(Info.t(), :raw) :: {:ok, :raw}
  defdelegate attachment_policy(info, requested), to: ModePolicy, as: :attachment_mode

  @doc "Opens a unified attachment handle for the given session."
  @spec attach(Info.t(), keyword()) :: {:ok, Attachment.t()} | {:error, term()}
  defdelegate attach(info, opts), to: Attachment, as: :open

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
        :exit, {:noproc, _} ->
          Logger.warning("terminal owner orphaned detach (no-op on dead owner)", owner: owner_pid)
          :telemetry.execute([:dev_ide, :terminals, :owner, :orphaned_detach], %{count: 1}, %{})
          :ok
      end
    else
      Logger.debug("terminal owner detach on dead pid (orphaned)", owner: owner_pid)
      :telemetry.execute([:dev_ide, :terminals, :owner, :orphaned_detach], %{count: 1}, %{})
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

  @doc """
  Reports whether the calling viewer is the active (visible + focused)
  attachment, so the owner can size the shared PTY to the focused viewer.
  """
  @spec owner_set_active(pid(), boolean()) :: :ok
  def owner_set_active(owner_pid, active?) when is_pid(owner_pid) and is_boolean(active?) do
    SessionOwner.set_active(owner_pid, active?)
  end

  @doc """
  Cheap subscriber count (map_size of subscribers) for the given owner pid.
  Enables UX (e.g. "3 viewers" badge) and dashboard queries for channel-raw
  owners. See SessionOwner.subscriber_count/1.
  """
  @spec owner_subscriber_count(pid()) :: non_neg_integer()
  def owner_subscriber_count(owner_pid) when is_pid(owner_pid) do
    SessionOwner.subscriber_count(owner_pid)
  end

  @doc """
  Raw shell attachment bridge (via GhosttyRawAdapter).

  Canonical entry for owner-driven raw joins that must coexist with
  PaneWorker/Ghostty-managed tmux sessions (short-term migration path).
  """
  @spec raw_shell_attach(String.t(), String.t(), term()) :: {:ok, pid()} | {:error, term()}
  def raw_shell_attach(workspace_id, sid, loc) do
    GhosttyRawAdapter.ensure_raw_shell(workspace_id, sid, loc)
  end
end
