defmodule FleetCtl.Protocol.Envelope do
  @moduledoc """
  Versioned protocol envelope for all controller ↔ runner messages.

  Every message on the wire — even locally — must be wrapped in an
  envelope before dispatch.
  """

  alias FleetCtl.Protocol.Messages

  @type t :: %__MODULE__{
          version: pos_integer(),
          message_id: String.t(),
          sent_at: DateTime.t(),
          runner_id: String.t(),
          lease_id: String.t(),
          payload: struct()
        }

  @enforce_keys [:version, :message_id, :sent_at, :runner_id, :lease_id, :payload]
  defstruct [
    :version,
    :message_id,
    :sent_at,
    :runner_id,
    :lease_id,
    :payload
  ]

  @current_version 1

  @doc "Wrap a message in an envelope."
  @spec wrap(struct(), keyword()) :: t()
  def wrap(payload, opts) when is_struct(payload) and is_list(opts) do
    %__MODULE__{
      version: @current_version,
      message_id: Keyword.get(opts, :message_id) || uuid4(),
      sent_at: Keyword.get(opts, :sent_at) || DateTime.utc_now(),
      runner_id: Keyword.fetch!(opts, :runner_id),
      lease_id: Keyword.fetch!(opts, :lease_id),
      payload: payload
    }
  end

  @doc "Serialize an envelope to a map suitable for JSON/transport."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = envelope) do
    %{
      "version" => envelope.version,
      "message_id" => envelope.message_id,
      "sent_at" => DateTime.to_iso8601(envelope.sent_at),
      "runner_id" => envelope.runner_id,
      "lease_id" => envelope.lease_id,
      "payload_type" => payload_type_name(envelope.payload),
      "payload" => struct_to_map(envelope.payload)
    }
  end

  @doc "Deserialize a map back into an envelope with a typed payload."
  @spec from_map(map()) :: {:ok, t()} | {:error, :unknown_payload | term()}
  def from_map(map) when is_map(map) do
    with {:ok, payload} <- parse_payload(map["payload_type"], map["payload"]) do
      {:ok,
       %__MODULE__{
         version: map["version"],
         message_id: map["message_id"],
         sent_at: parse_datetime(map["sent_at"]),
         runner_id: map["runner_id"],
         lease_id: map["lease_id"],
         payload: payload
       }}
    end
  end

  @doc "Generate a UUID v4 string using `:crypto`."
  @spec uuid4() :: String.t()
  def uuid4 do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

    <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(<<hex::binary-size(32)>>) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp payload_type_name(%type{}), do: Atom.to_string(type) |> String.split(".") |> List.last()

  defp struct_to_map(%_{} = struct) do
    Map.from_struct(struct)
    |> Enum.map(fn {k, v} ->
      {to_string(k),
       case v do
         %DateTime{} = dt -> DateTime.to_iso8601(dt)
         val -> val
       end}
    end)
    |> Map.new()
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(val) when is_binary(val) do
    case DateTime.from_iso8601(val) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(val), do: val

  defp parse_payload(type_name, attrs) do
    case type_name do
      "AssignmentOffered" ->
        {:ok,
         %Messages.AssignmentOffered{
           assignment_id: attrs["assignment_id"],
           safe_action_id: attrs["safe_action_id"],
           workspace_id: attrs["workspace_id"],
           worktree_path: attrs["worktree_path"],
           lease_duration_ms: attrs["lease_duration_ms"]
         }}

      "AssignmentAccepted" ->
        {:ok, %Messages.AssignmentAccepted{assignment_id: attrs["assignment_id"]}}

      "AssignmentRejected" ->
        {:ok,
         %Messages.AssignmentRejected{
           assignment_id: attrs["assignment_id"],
           reason: attrs["reason"]
         }}

      "AssignmentRevoked" ->
        {:ok,
         %Messages.AssignmentRevoked{
           assignment_id: attrs["assignment_id"],
           reason: attrs["reason"]
         }}

      "ExecutionStarted" ->
        {:ok,
         %Messages.ExecutionStarted{
           assignment_id: attrs["assignment_id"],
           execution_id: attrs["execution_id"],
           started_at: parse_datetime(attrs["started_at"])
         }}

      "ExecutionCompleted" ->
        {:ok,
         %Messages.ExecutionCompleted{
           assignment_id: attrs["assignment_id"],
           execution_id: attrs["execution_id"],
           completed_at: parse_datetime(attrs["completed_at"]),
           evidence: attrs["evidence"] || %{}
         }}

      "ExecutionFailed" ->
        {:ok,
         %Messages.ExecutionFailed{
           assignment_id: attrs["assignment_id"],
           execution_id: attrs["execution_id"],
           failed_at: parse_datetime(attrs["failed_at"]),
           reason: attrs["reason"],
           evidence: attrs["evidence"] || %{}
         }}

      "ExecutionAbandoned" ->
        {:ok,
         %Messages.ExecutionAbandoned{
           assignment_id: attrs["assignment_id"],
           execution_id: attrs["execution_id"],
           reason: attrs["reason"]
         }}

      "OutputChunk" ->
        {:ok,
         %Messages.OutputChunk{
           assignment_id: attrs["assignment_id"],
           execution_id: attrs["execution_id"],
           stream: attrs["stream"],
           chunk: attrs["chunk"],
           seq: attrs["seq"],
           timestamp: parse_datetime(attrs["timestamp"])
         }}

      "ArtifactChunk" ->
        {:ok,
         %Messages.ArtifactChunk{
           assignment_id: attrs["assignment_id"],
           execution_id: attrs["execution_id"],
           artifact_id: attrs["artifact_id"],
           chunk: attrs["chunk"],
           position: attrs["position"],
           timestamp: parse_datetime(attrs["timestamp"])
         }}

      "Telemetry" ->
        {:ok,
         %Messages.Telemetry{
           runner_id: attrs["runner_id"],
           cpu_percent: attrs["cpu_percent"],
           memory_mb: attrs["memory_mb"],
           timestamp: parse_datetime(attrs["timestamp"])
         }}

      "Heartbeat" ->
        {:ok,
         %Messages.Heartbeat{
           runner_id: attrs["runner_id"],
           active_assignment_id: attrs["active_assignment_id"]
         }}

      "LeaseRenewed" ->
        {:ok,
         %Messages.LeaseRenewed{
           lease_id: attrs["lease_id"],
           expires_at: parse_datetime(attrs["expires_at"])
         }}

      _ ->
        {:error, :unknown_payload}
    end
  end
end
