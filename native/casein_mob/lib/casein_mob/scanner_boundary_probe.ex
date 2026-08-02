defmodule CaseinMob.ScannerBoundaryProbe do
  @moduledoc false

  use GenServer

  require Logger

  alias CaseinMob.PairingCode

  @name :casein_scanner_boundary_probe
  @max_code_bytes 4_096
  @compact_prefix "casein://pair/"
  @barcode_types [:ean13, :ean8, :code128, :code39, :upca, :upce, :pdf417, :aztec, :data_matrix]
  @reason_labels %{
    empty: "empty",
    invalid_encoding: "invalid_encoding",
    invalid_json: "invalid_json",
    invalid_payload: "invalid_payload",
    invalid_structure: "invalid_structure"
  }

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ready, name: @name)
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_info({:scan, :result, %{type: type, value: value}}, state) do
    diagnostics = diagnose(type, value)

    Logger.info(
      "ios_scanner_boundary_probe scan_type=#{diagnostics.scan_type} " <>
        "byte_count=#{diagnostics.byte_count} " <>
        "compact_prefix=#{diagnostics.compact_prefix?} " <>
        "base64url_segment=#{diagnostics.base64url_segment?} " <>
        "rejection_stage=#{diagnostics.rejection_stage} " <>
        "rejection_reason=#{diagnostics.rejection_reason}"
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def diagnose(type, value) when is_binary(value) do
    {compact_prefix?, base64url_segment?} = structural_flags(value)

    {rejection_stage, rejection_reason} =
      case safe_decode(value) do
        {:ok, _payload} -> {"none", "none"}
        {:error, reason} -> {"pairing_code", Map.get(@reason_labels, reason, "other")}
      end

    %{
      scan_type: scan_type(type),
      byte_count: min(byte_size(value), @max_code_bytes),
      compact_prefix?: compact_prefix?,
      base64url_segment?: base64url_segment?,
      rejection_stage: rejection_stage,
      rejection_reason: rejection_reason
    }
  end

  def diagnose(type, _value) do
    %{
      scan_type: scan_type(type),
      byte_count: 0,
      compact_prefix?: false,
      base64url_segment?: false,
      rejection_stage: "pairing_code",
      rejection_reason: "invalid_structure"
    }
  end

  defp safe_decode(value) do
    PairingCode.decode(value)
  rescue
    ArgumentError -> {:error, :invalid_structure}
  end

  defp structural_flags(value) when byte_size(value) <= @max_code_bytes do
    trimmed = safe_trim(value)
    compact_prefix? = String.starts_with?(trimmed, @compact_prefix)

    segment =
      if compact_prefix?,
        do: String.replace_prefix(trimmed, @compact_prefix, ""),
        else: ""

    base64url_segment? =
      compact_prefix? and segment != "" and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, segment)

    {compact_prefix?, base64url_segment?}
  end

  defp structural_flags(_value), do: {false, false}

  defp safe_trim(value) do
    String.trim(value)
  rescue
    ArgumentError -> ""
  end

  defp scan_type(:qr), do: "qr"
  defp scan_type(type) when type in @barcode_types, do: "barcode"
  defp scan_type(_type), do: "other"
end
