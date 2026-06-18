defmodule DevIDE.Terminals.Attachment do
  @moduledoc """
  Unified attachment handle for a terminal session.

  Shell sessions attach to a tmux/Ghostty PTY via `GhosttyRawAdapter`.
  `:execution` sessions attach to a read-only `ExecutionStreamer` (input is a
  no-op; output is polled from local tmux when the session is live). The handle
  records the backend module explicitly, so dispatch is deterministic. The
  `:agent` kind has no backend and returns an error on open.
  """

  alias DevIDE.Terminals.{
    ExecutionStreamer,
    GhosttyRawAdapter,
    Session
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

    streamer_opts =
      [subscriber: subscriber]
      |> maybe_put(:tmux_session, info.tmux_session)
      |> maybe_put(:execution_id, info.execution_id)

    case DynamicSupervisor.start_child(
           DevIDE.Terminals.Supervisor,
           {ExecutionStreamer, streamer_opts}
         ) do
      {:ok, pid} -> {:ok, %__MODULE__{kind: :execution, backend: ExecutionStreamer, pid: pid}}
      {:error, _} = err -> err
    end
  end

  # Agent groundwork — backend not yet implemented.
  def open(%Info{kind: :agent}, _opts), do: {:error, :agent_backend_unavailable}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Sends user input.

  All backends expose `send_input/2`; remote executions intentionally treat it
  as a no-op (no protocol path back to the remote pty). The decision lives in
  the backend, not here.
  """
  @spec send_input(t(), binary()) :: :ok
  def send_input(%__MODULE__{backend: backend, pid: pid}, data),
    do: backend.send_input(pid, data)

  @doc """
  Authoritative retained-output snapshot for replay, when the backend keeps
  one. Shell sessions return the `Session` process's bounded buffer — which
  captures output continuously, unlike any per-owner buffer that only sees
  data while subscribed. Streamers replay independently on attach and
  return `:unavailable`.
  """
  @spec snapshot(t()) :: {:ok, binary()} | :unavailable
  def snapshot(%__MODULE__{backend: Session, pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        {:ok, Session.snapshot(pid)}
      catch
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  def snapshot(%__MODULE__{}), do: :unavailable

  @doc "Resizes the underlying pty/window."
  @spec resize(t(), pos_integer(), pos_integer()) :: :ok
  def resize(%__MODULE__{backend: Session, pid: pid}, cols, rows)
      when is_integer(cols) and is_integer(rows),
      do: Session.resize(pid, cols, rows)

  def resize(%__MODULE__{}, _cols, _rows), do: :ok

  @doc """
  Releases the attachment.

  Shell PTYs persist across reconnects (owned by the workspace Session
  process), so close is a no-op there. The execution streamer is channel-owned
  and stopped.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{backend: Session}), do: :ok

  def close(%__MODULE__{backend: ExecutionStreamer, pid: pid}) do
    if Process.alive?(pid), do: ExecutionStreamer.stop(pid)
    :ok
  end

  # ---- internals ----

  defp subscribe_shell(pid, subscriber) when subscriber == self() do
    try do
      Session.subscribe(pid)
    catch
      :exit, _ -> {:error, :pty_unavailable}
    end
  end

  defp subscribe_shell(_pid, _other), do: {:error, :subscriber_must_be_caller}
end
