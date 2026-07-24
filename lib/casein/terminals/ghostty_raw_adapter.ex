defmodule Casein.Terminals.GhosttyRawAdapter do
  @moduledoc """
  Migration bridge / adapter for raw shell channel joins.

  Enables raw joins (e.g. `terminal:<ws>:<sid>` via TerminalChannel)
  to be serviced through SessionOwner. SessionOwner opens this bridge when it
  needs the underlying tmux-backed `Terminals.Session` PTY.

  Current guarantees:
  - Delegates shell PTY startup to `Terminals.Session` keyed by `{workspace, sid}`.
  - LiveView panes use the `:session_owner` backend by default, so matching raw
    channel joins reuse the same SessionOwner process and its attachment.
  - Channel and LiveView raw subscribers receive replay + live data via
    SessionOwner without starting an extra PaneWorker/Ghostty.PTY client.

  The legacy PaneWorker `:ghostty_pty` backend and intermediate
  `:shared_session` backend remain available for tests/rollback rather than the
  production default.

  All errors are surfaced cleanly to callers (no swallowed child failures).
  """

  alias Casein.Terminals.Session

  @doc """
  Ensures the canonical raw shell PTY owner is running for the given
  `(workspace, sid, loc)`.
  """
  @spec ensure_raw_shell(String.t(), String.t(), Session.loc()) :: {:ok, pid()} | {:error, term()}
  def ensure_raw_shell(workspace, sid, loc) do
    # Emit distinct telemetry for the bridge path so dashboards can observe
    # raw channel attaches reusing the canonical Terminals.Session boundary.
    do_ensure_and_emit_bridge_telemetry(workspace, sid, loc)
  end

  defp do_ensure_and_emit_bridge_telemetry(workspace, sid, loc) do
    reuse? =
      case Session.whereis(workspace, sid) do
        {:ok, _pid} -> true
        :error -> false
      end

    result = Session.ensure_started(workspace, sid, loc)

    if match?({:ok, _}, result) do
      :telemetry.execute([:casein, :terminals, :raw_bridge, :attach], %{count: 1}, %{
        workspace: workspace,
        sid: sid,
        reuse: reuse?,
        kind: :shell
      })
    end

    result
  end

  @doc """
  Lightweight bridge visibility hook: true when a shared tmux-backed Session
  for this `(workspace, sid)` is already alive.

  This is the canonical handoff probe for future migrations toward a single
  terminal ownership boundary (avoid unnecessary raw shell bootstraps when a
  live canonical session already exists).
  """
  @spec raw_session_active?(String.t(), String.t()) :: boolean()
  def raw_session_active?(workspace, sid) do
    case Session.whereis(workspace, sid) do
      {:ok, _pid} -> true
      _ -> false
    end
  end
end
