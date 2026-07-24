defmodule Casein.Terminals.SessionOwner.Payload do
  @moduledoc false

  # Enriched replay payload with state marker for raw channel reconnect UX.
  # `replay_frame: true` + `state_marker` let TerminalChannel clients
  # distinguish buffered scrollback from live PTY output. Cursor metadata is
  # opportunistic: if a backend emits a cursor report, it is captured and
  # stripped before broadcast/buffering; otherwise clients get the pending
  # placeholder.
  def build_data_payload(data, true, cursor, gen) when is_binary(data) do
    %{
      data: data,
      gen: gen,
      replay: true,
      replay_frame: true,
      state_marker: %{
        kind: "replay",
        cursor: cursor || %{row: nil, col: nil, pending: true},
        ts: System.system_time(:millisecond)
      }
    }
  end

  def build_data_payload(data, _replay, _cursor, gen) when is_binary(data),
    do: %{data: data, gen: gen}
end
