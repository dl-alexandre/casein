defmodule CaseinMob.MobileTerminalStream do
  @moduledoc """
  Pure, connection-scoped parser for the frozen `mobile_terminal_v1` byte plane.

  The parser never stores terminal bytes. It retains only a bounded ledger of
  frame digests so an exact replay can be ignored without accepting overlaps.
  Any malformed, stale, discontinuous, or wrong-generation frame purges the
  stream identity and requires a new authoritative baseline.
  """

  @schema "mobile_terminal_v1"
  @mode "read"
  @max_payload_bytes 65_536
  @max_identity_bytes 256
  @duplicate_ledger_limit 64
  @cutoff_reasons ~w(
    invalid_payload unauthorized not_found unavailable feature_disabled
    kill_switch_active policy_denied inactive_origin stale_lease stale_grant
    grant_expired grant_revoked grant_already_used identity_mismatch
    pane_identity_mismatch pane_role_mismatch topology_mismatch
    connection_generation_mismatch offset_mismatch read_only
  )

  @type reason ::
          :invalid_payload
          | :identity_mismatch
          | :connection_generation_mismatch
          | :stream_generation_mismatch
          | :baseline_required
          | :offset_mismatch
          | :cutoff

  @type status :: :awaiting_baseline | :live | :cutoff

  @type t :: %__MODULE__{
          lease_id: String.t(),
          lifecycle_generation: String.t(),
          connection_generation: String.t(),
          stream_generation: String.t() | nil,
          next_offset: non_neg_integer() | nil,
          status: status(),
          duplicate_ledger: %{optional({non_neg_integer(), non_neg_integer()}) => binary()},
          duplicate_order: [{non_neg_integer(), non_neg_integer()}]
        }

  @enforce_keys [:lease_id, :lifecycle_generation, :connection_generation]
  defstruct [
    :lease_id,
    :lifecycle_generation,
    :connection_generation,
    :stream_generation,
    :next_offset,
    status: :awaiting_baseline,
    duplicate_ledger: %{},
    duplicate_order: []
  ]

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, :invalid_identity}
  def new(identities) when is_map(identities) or is_list(identities) do
    with {:ok, lease_id} <- identity(identities, :lease_id),
         {:ok, lifecycle_generation} <- identity(identities, :lifecycle_generation),
         {:ok, connection_generation} <- identity(identities, :connection_generation) do
      {:ok,
       %__MODULE__{
         lease_id: lease_id,
         lifecycle_generation: lifecycle_generation,
         connection_generation: connection_generation
       }}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  @doc """
  Accept one decoded channel payload.

  Successful stream frames return their decoded bytes exactly once. Duplicate
  frames return no bytes. Resync and cutoff outcomes contain only bounded atoms
  or allowlisted cutoff reasons; raw payload values never enter an error.
  """
  @spec accept(t(), term()) ::
          {:ok, t(), binary()}
          | {:duplicate, t()}
          | {:resync, t(), reason()}
          | {:cutoff, t(), String.t()}
  def accept(%__MODULE__{} = state, payload) when is_map(payload) do
    case fetch(payload, :event) do
      "terminal_baseline" -> accept_baseline(state, payload)
      "terminal_output" -> accept_output(state, payload)
      "terminal_cutoff" -> accept_cutoff(state, payload)
      _ -> resync(state, :invalid_payload)
    end
  end

  def accept(%__MODULE__{} = state, _payload), do: resync(state, :invalid_payload)

  @spec awaiting_baseline?(t()) :: boolean()
  def awaiting_baseline?(%__MODULE__{status: :awaiting_baseline}), do: true
  def awaiting_baseline?(%__MODULE__{}), do: false

  defp accept_baseline(%__MODULE__{status: status} = state, payload)
       when status in [:awaiting_baseline, :live] do
    with {:ok, frame} <- decode_stream_frame(payload, "terminal_baseline"),
         :ok <- validate_connection_identity(state, frame) do
      cond do
        state.status == :live and exact_duplicate?(state, frame) ->
          {:duplicate, state}

        state.status == :live ->
          resync(state, :baseline_required)

        true ->
          accepted =
            state
            |> Map.put(:status, :live)
            |> Map.put(:stream_generation, frame.stream_generation)
            |> Map.put(:next_offset, frame.next_offset)
            |> remember(frame)

          {:ok, accepted, frame.bytes}
      end
    else
      {:error, reason} -> resync(state, reason)
    end
  end

  defp accept_baseline(%__MODULE__{} = state, _payload), do: resync(state, :cutoff)

  defp accept_output(%__MODULE__{status: :live} = state, payload) do
    with {:ok, frame} <- decode_stream_frame(payload, "terminal_output"),
         :ok <- validate_connection_identity(state, frame),
         :ok <- validate_stream_generation(state, frame) do
      cond do
        exact_duplicate?(state, frame) ->
          {:duplicate, state}

        frame.offset == state.next_offset and not seen_offset_range?(state, frame) ->
          accepted = state |> Map.put(:next_offset, frame.next_offset) |> remember(frame)
          {:ok, accepted, frame.bytes}

        true ->
          resync(state, :offset_mismatch)
      end
    else
      {:error, reason} -> resync(state, reason)
    end
  end

  defp accept_output(%__MODULE__{status: :awaiting_baseline} = state, _payload),
    do: resync(state, :baseline_required)

  defp accept_output(%__MODULE__{} = state, _payload), do: resync(state, :cutoff)

  defp accept_cutoff(state, payload) do
    with :ok <- validate_cutoff_envelope(payload),
         {:ok, lease_id} <- payload_identity(payload, :lease_id),
         {:ok, connection_generation} <- payload_identity(payload, :connection_generation),
         true <- lease_id == state.lease_id,
         true <- connection_generation == state.connection_generation,
         reason when reason in @cutoff_reasons <- fetch(payload, :reason) do
      {:cutoff, purge(state, :cutoff), reason}
    else
      false -> resync(state, :identity_mismatch)
      _ -> resync(state, :invalid_payload)
    end
  end

  defp decode_stream_frame(payload, event) do
    with :ok <- validate_envelope(payload, event),
         {:ok, lease_id} <- payload_identity(payload, :lease_id),
         {:ok, lifecycle_generation} <- payload_identity(payload, :lifecycle_generation),
         {:ok, connection_generation} <- payload_identity(payload, :connection_generation),
         {:ok, stream_generation} <- payload_identity(payload, :stream_generation),
         offset when is_integer(offset) and offset >= 0 <- fetch(payload, :offset),
         next_offset when is_integer(next_offset) and next_offset >= offset <-
           fetch(payload, :next_offset),
         truncated when is_boolean(truncated) <- fetch(payload, :truncated),
         encoded when is_binary(encoded) <- fetch(payload, :bytes_base64),
         {:ok, bytes} <- decode_bounded_base64(encoded),
         true <- next_offset == offset + byte_size(bytes) do
      {:ok,
       %{
         event: event,
         lease_id: lease_id,
         lifecycle_generation: lifecycle_generation,
         connection_generation: connection_generation,
         stream_generation: stream_generation,
         offset: offset,
         next_offset: next_offset,
         truncated: truncated,
         bytes: bytes
       }}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp validate_envelope(payload, event) do
    if fetch(payload, :schema) == @schema and fetch(payload, :event) == event and
         fetch(payload, :mode) == @mode,
       do: :ok,
       else: {:error, :invalid_payload}
  end

  defp validate_cutoff_envelope(payload) do
    if fetch(payload, :schema) == @schema and fetch(payload, :event) == "terminal_cutoff",
      do: :ok,
      else: {:error, :invalid_payload}
  end

  defp validate_connection_identity(state, frame) do
    cond do
      frame.lease_id != state.lease_id ->
        {:error, :identity_mismatch}

      frame.lifecycle_generation != state.lifecycle_generation ->
        {:error, :identity_mismatch}

      frame.connection_generation != state.connection_generation ->
        {:error, :connection_generation_mismatch}

      true ->
        :ok
    end
  end

  defp validate_stream_generation(state, frame) do
    if frame.stream_generation == state.stream_generation,
      do: :ok,
      else: {:error, :stream_generation_mismatch}
  end

  # A base64 string longer than this cannot decode within the byte cap. Reject
  # it before decoding so attacker-controlled allocation remains bounded.
  defp decode_bounded_base64(encoded) do
    max_encoded_bytes = 4 * div(@max_payload_bytes + 2, 3)

    if byte_size(encoded) <= max_encoded_bytes do
      case Base.decode64(encoded) do
        {:ok, bytes} when byte_size(bytes) <= @max_payload_bytes -> {:ok, bytes}
        _ -> {:error, :invalid_payload}
      end
    else
      {:error, :invalid_payload}
    end
  end

  defp validate_identity(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_identity_bytes,
       do: {:ok, value}

  defp validate_identity(_value), do: {:error, :invalid_identity}

  defp identity(values, key), do: values |> fetch(key) |> validate_identity()

  defp payload_identity(payload, key) do
    case validate_identity(fetch(payload, key)) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :invalid_payload}
    end
  end

  defp exact_duplicate?(state, frame) do
    Map.get(state.duplicate_ledger, {frame.offset, frame.next_offset}) == digest(frame)
  end

  defp seen_offset_range?(state, frame) do
    Map.has_key?(state.duplicate_ledger, {frame.offset, frame.next_offset})
  end

  defp remember(state, frame) do
    key = {frame.offset, frame.next_offset}
    order = [key | Enum.reject(state.duplicate_order, &(&1 == key))]
    ledger = Map.put(state.duplicate_ledger, key, digest(frame))

    {kept, dropped} = Enum.split(order, @duplicate_ledger_limit)
    ledger = Enum.reduce(dropped, ledger, &Map.delete(&2, &1))
    %{state | duplicate_ledger: ledger, duplicate_order: kept}
  end

  defp digest(frame) do
    truncated = if frame.truncated, do: <<1>>, else: <<0>>
    :crypto.hash(:sha256, [frame.event, <<0>>, frame.bytes, truncated])
  end

  defp resync(state, reason), do: {:resync, purge(state, :awaiting_baseline), reason}

  defp purge(state, status) do
    %{
      state
      | status: status,
        stream_generation: nil,
        next_offset: nil,
        duplicate_ledger: %{},
        duplicate_order: []
    }
  end

  defp fetch(values, key) when is_list(values), do: Keyword.get(values, key)

  defp fetch(values, key) when is_map(values) do
    case Map.fetch(values, key) do
      {:ok, value} -> value
      :error -> Map.get(values, Atom.to_string(key))
    end
  end
end
