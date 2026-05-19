defmodule DevIDE.Terminals.Attachment do
  @moduledoc """
  Unified attachment handle for any terminal session.

  Phase 2 unified shell PTY + local fleet tmux through one handle. Phase 3
  extends it to remote executions (PubSub-driven `RemoteOutputStreamer`) and
  reserves the `:agent` kind for future work. The handle records the backend
  module explicitly, so dispatch is deterministic regardless of session kind.

  ## Shape decision (post-Phase 3 audit)

  Considered turning this into a `@behaviour` over the three backends. Rejected
  because:

    * Backends share `send_input/2`, but `resize/3` is shell-only by design
      (the cockpit can't resize a remote pty), and `close/1` for `Session` is
      intentionally a no-op (PTY persists across reconnects). A behaviour
      would force lying stubs on the streamers.
    * Per-op dispatch is already one line for `send_input` and small for the
      others. The remaining case clauses encode real behavioural differences,
      not boilerplate.
    * Adding a fourth backend means one new module + one branch in
      `open_execution/2` (or a new `open/2` clause for a new kind). That's the
      same cost as implementing a behaviour callback.

  Re-evaluate this if we reach 4+ backends with truly uniform contracts.
  """

  alias DevIDE.Terminals.{
    FleetSessionStreamer,
    GhosttyRawAdapter,
    RemoteOutputStreamer,
    Session,
    TmuxAdapter
  }

  alias DevIDE.Terminals.Session.Info

  defstruct [:kind, :backend, :pid, :ref, :cols, :rows]

  @type t :: %__MODULE__{
          kind: Info.kind(),
          backend: module(),
          pid: pid(),
          ref: reference() | nil,
          cols: pos_integer() | nil,
          rows: pos_integer() | nil
        }

  @doc """
  Opens an attachment.

  Required opts:
    * `:subscriber` — pid receiving `{:term_data, ...}` / `{:term_exit, ...}`.

  Shell-only opts:
    * `:workspace_key` — workspace name or id keying the Registry.
    * `:loc` — `Terminals.Session.loc()` (cwd or remote ssh).
  """
  @spec open(Info.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%Info{kind: :shell, sid: sid}, opts) do
    workspace_key = Keyword.fetch!(opts, :workspace_key)
    loc = Keyword.fetch!(opts, :loc)
    subscriber = Keyword.get(opts, :subscriber, self())

    # Raw shell attachment routed through GhosttyRawAdapter (migration bridge):
    # allows channel raw joins (owner/attachment path) to attach cleanly to
    # tmux sessions that may already be live under a PaneWorker/Ghostty.PTY
    # (via tmux -A reuse). Ghostty primary path remains untouched.
    with {:ok, pid} <- GhosttyRawAdapter.ensure_raw_shell(workspace_key, sid, loc),
         {:ok, ref, cols, rows} <- subscribe_shell(pid, subscriber) do
      {:ok,
       %__MODULE__{
         kind: :shell,
         backend: Session,
         pid: pid,
         ref: ref,
         cols: cols,
         rows: rows
       }}
    end
  end

  def open(%Info{kind: :execution} = info, opts) do
    subscriber = Keyword.get(opts, :subscriber, self())
    open_execution(info, subscriber)
  end

  # Agent groundwork — backend not yet implemented.
  def open(%Info{kind: :agent}, _opts), do: {:error, :agent_backend_unavailable}

  @doc """
  Sends user input.

  All backends expose `send_input/2`; remote executions intentionally treat it
  as a no-op (no protocol path back to the remote pty). The decision lives in
  the backend, not here.
  """
  @spec send_input(t(), binary()) :: :ok
  def send_input(%__MODULE__{backend: backend, pid: pid}, data),
    do: backend.send_input(pid, data)

  @doc "Resizes the underlying pty/window. No-op for fleet executions."
  @spec resize(t(), pos_integer(), pos_integer()) :: :ok
  def resize(%__MODULE__{backend: Session, pid: pid}, cols, rows)
      when is_integer(cols) and is_integer(rows),
      do: Session.resize(pid, cols, rows)

  def resize(%__MODULE__{}, _cols, _rows), do: :ok

  @doc """
  Releases the attachment.

  Shell PTYs persist across reconnects (owned by the workspace Session
  process), so close is a no-op there. Streamers are channel-owned and stopped.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{backend: Session}), do: :ok

  def close(%__MODULE__{backend: backend, pid: pid})
      when backend in [FleetSessionStreamer, RemoteOutputStreamer] do
    if Process.alive?(pid), do: backend.stop(pid)
    :ok
  end

  # ---- internals ----

  defp open_execution(%Info{tmux_session: tmux} = info, subscriber)
       when is_binary(tmux) do
    if local_tmux_attachable?(info) do
      start_streamer(
        FleetSessionStreamer,
        tmux_session: tmux,
        subscriber: subscriber
      )
    else
      start_streamer(
        RemoteOutputStreamer,
        execution_id: info.execution_id,
        subscriber: subscriber
      )
    end
  end

  defp open_execution(%Info{execution_id: exec_id}, subscriber) when is_binary(exec_id) do
    start_streamer(RemoteOutputStreamer, execution_id: exec_id, subscriber: subscriber)
  end

  defp open_execution(_info, _subscriber), do: {:error, :execution_unattachable}

  # `loc: :remote` is the explicit signal. Otherwise we fall back to probing
  # local tmux — protects us if a remote runner's tmux session name happens to
  # collide with a stale local one (won't be alive on this host).
  defp local_tmux_attachable?(%Info{loc: :remote}), do: false

  defp local_tmux_attachable?(%Info{tmux_session: tmux}) when is_binary(tmux),
    do: TmuxAdapter.session_alive?(tmux)

  defp local_tmux_attachable?(_), do: false

  defp start_streamer(module, opts) do
    case DynamicSupervisor.start_child(DevIDE.Terminals.Supervisor, {module, opts}) do
      {:ok, pid} -> {:ok, %__MODULE__{kind: :execution, backend: module, pid: pid}}
      {:error, _} = err -> err
    end
  end

  defp subscribe_shell(pid, subscriber) when subscriber == self(), do: Session.subscribe(pid)
  defp subscribe_shell(_pid, _other), do: {:error, :subscriber_must_be_caller}
end
