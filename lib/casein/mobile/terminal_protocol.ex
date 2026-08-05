defmodule Casein.Mobile.TerminalProtocol do
  @moduledoc """
  Frozen `mobile_terminal_v1` wire contract for read-only mobile terminals.

  Control messages travel on `mobile:user:*`; terminal bytes travel only on the
  lease-scoped `mobile_terminal:<lease_id>` channel. Raw bytes are base64 and
  bounded by `max_payload_bytes/0`. Clients must accept the join baseline before
  applying live output with the same stream generation and contiguous offset.
  """

  @schema "mobile_terminal_v1"
  @mode "read"
  @max_payload_bytes 65_536
  @control_events ~w(terminal_create terminal_delete terminal_refresh)
  @channel_events ~w(terminal_baseline terminal_output terminal_cutoff)
  @rejected_channel_events ~w(terminal_input terminal_paste terminal_query)
  @error_codes ~w(
    invalid_payload unauthorized not_found unavailable feature_disabled
    kill_switch_active policy_denied inactive_origin stale_lease stale_grant
    grant_expired grant_revoked grant_already_used identity_mismatch
    pane_identity_mismatch pane_role_mismatch topology_mismatch
    connection_generation_mismatch offset_mismatch read_only
  )

  def schema, do: @schema
  def mode, do: @mode
  def max_payload_bytes, do: @max_payload_bytes
  def control_events, do: @control_events
  def channel_events, do: @channel_events
  def rejected_channel_events, do: @rejected_channel_events
  def error_codes, do: @error_codes

  def topic(lease_id) when is_binary(lease_id), do: "mobile_terminal:" <> lease_id

  def control_reply(status, lease, grant)
      when status in ["created", "refreshed"] and is_map(lease) and is_map(grant) do
    %{
      "schema" => @schema,
      "status" => status,
      "mode" => @mode,
      "lease" => lease,
      "child_grant" => grant,
      "channel_topic" => topic(fetch!(lease, :id))
    }
  end

  def delete_reply(lease_id) when is_binary(lease_id) do
    %{"schema" => @schema, "status" => "deleted", "lease_id" => lease_id}
  end

  def baseline(fields), do: stream_payload("terminal_baseline", fields)
  def output(fields), do: stream_payload("terminal_output", fields)

  def cutoff(lease_id, connection_generation, reason)
      when is_binary(lease_id) and is_binary(connection_generation) and reason in @error_codes do
    %{
      "schema" => @schema,
      "event" => "terminal_cutoff",
      "lease_id" => lease_id,
      "connection_generation" => connection_generation,
      "reason" => reason
    }
  end

  def error(reason) when reason in @error_codes,
    do: %{"schema" => @schema, "reason" => reason}

  def error(_reason), do: %{"schema" => @schema, "reason" => "unavailable"}

  defp stream_payload(event, fields) when is_map(fields) do
    bytes = fetch!(fields, :bytes)

    if is_binary(bytes) and byte_size(bytes) <= @max_payload_bytes do
      %{
        "schema" => @schema,
        "event" => event,
        "lease_id" => fetch!(fields, :lease_id),
        "lifecycle_generation" => fetch!(fields, :lifecycle_generation),
        "connection_generation" => fetch!(fields, :connection_generation),
        "stream_generation" => fetch!(fields, :stream_generation),
        "offset" => fetch!(fields, :offset),
        "next_offset" => fetch!(fields, :offset) + byte_size(bytes),
        "bytes_base64" => Base.encode64(bytes),
        "truncated" => Map.get(fields, :truncated, false),
        "mode" => @mode
      }
    else
      raise ArgumentError, "terminal payload exceeds bounded contract"
    end
  end

  defp fetch!(map, key), do: Map.get(map, key) || Map.fetch!(map, Atom.to_string(key))
end
