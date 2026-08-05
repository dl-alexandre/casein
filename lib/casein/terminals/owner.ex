defmodule Casein.Terminals.Owner do
  @moduledoc false

  require Logger

  alias Casein.Terminals.{
    Attachment,
    GhosttyRawAdapter,
    GhosttySnapshot,
    Session,
    SessionOwner,
    Theme
  }

  alias Casein.Terminals.Session.Info

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
          :telemetry.execute([:casein, :terminals, :owner, :orphaned_detach], %{count: 1}, %{})
          :ok
      end
    else
      Logger.debug("terminal owner detach on dead pid (orphaned)", owner: owner_pid)
      :telemetry.execute([:casein, :terminals, :owner, :orphaned_detach], %{count: 1}, %{})
      :ok
    end
  end

  @doc "Sends raw terminal input through the terminal owner."
  @spec owner_input(pid(), binary()) :: :ok
  def owner_input(owner_pid, data) when is_pid(owner_pid) and is_binary(data) do
    SessionOwner.input(owner_pid, data)
  end

  @doc """
  Forwards a viewer-generated terminal query response through the owner's
  single-responder gate (raw bytes; the owner rewrites with the session theme).
  """
  @spec owner_query_response(pid(), binary()) :: :ok
  def owner_query_response(owner_pid, data) when is_pid(owner_pid) and is_binary(data) do
    SessionOwner.query_response(owner_pid, data)
  end

  @doc "Sets the session-level terminal theme on the owner (last writer wins)."
  @spec owner_set_theme(pid(), Theme.scheme(), String.t()) :: :ok
  def owner_set_theme(owner_pid, scheme, preset)
      when is_pid(owner_pid) and scheme in [:dark, :light] and is_binary(preset) do
    SessionOwner.set_theme(owner_pid, scheme, preset)
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

  @doc "Returns the immutable owner incarnation and current output generation."
  @spec owner_identity(pid()) :: map()
  def owner_identity(owner_pid) when is_pid(owner_pid), do: SessionOwner.identity(owner_pid)

  @doc "Stops the exact shell owner without changing ordinary detach semantics."
  def stop_shell_owner(workspace_id, sid), do: SessionOwner.stop_shell(workspace_id, sid)

  @doc "Stops the exact PTY process without killing or enumerating tmux siblings."
  def stop_session_exact(workspace_key, sid), do: Session.stop_exact(workspace_key, sid)

  @doc """
  Raw shell attachment bridge (via GhosttyRawAdapter).

  Canonical entry for owner-driven raw joins that must coexist with
  PaneWorker/Ghostty-managed tmux sessions (short-term migration path).
  """
  @spec raw_shell_attach(String.t(), String.t(), term()) :: {:ok, pid()} | {:error, term()}
  def raw_shell_attach(workspace_id, sid, loc) do
    GhosttyRawAdapter.ensure_raw_shell(workspace_id, sid, loc)
  end

  @doc "Default legacy terminal session backend module."
  @spec session_backend_module() :: module()
  def session_backend_module, do: Session

  @doc "Sends input through the legacy shared terminal session backend."
  @spec send_session_input(pid(), binary()) :: :ok
  def send_session_input(session_pid, data) when is_pid(session_pid) and is_binary(data) do
    Session.send_input(session_pid, data)
  end

  @doc "Captures a Ghostty terminal snapshot artifact set."
  @spec capture_ghostty_snapshot(pid(), String.t()) :: map()
  def capture_ghostty_snapshot(term, workspace_id) do
    GhosttySnapshot.capture(term, workspace_id)
  end
end
