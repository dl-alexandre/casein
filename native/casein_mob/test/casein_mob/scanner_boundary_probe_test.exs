defmodule CaseinMob.ScannerBoundaryProbeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CaseinMob.ScannerBoundaryProbe

  @vector_path Path.expand("../fixtures/compact_pairing_vectors.json", __DIR__)

  test "golden scanner result reaches the normal parser with fixed diagnostics" do
    [vector] = Jason.decode!(File.read!(@vector_path))
    pid = start_supervised!({ScannerBoundaryProbe, []})

    log =
      capture_log([level: :info], fn ->
        send(pid, {:scan, :result, %{type: :qr, value: vector["uri"]}})
        assert :ready = :sys.get_state(pid)
      end)

    assert log =~
             "ios_scanner_boundary_probe scan_type=qr byte_count=146 " <>
               "compact_prefix=true base64url_segment=true " <>
               "rejection_stage=none rejection_reason=none"

    refute log =~ vector["uri"]
    refute log =~ vector["handle"]
    refute log =~ vector["origin"]
  end

  test "scan categories and parser failures are reduced to fixed labels" do
    assert %{
             scan_type: "barcode",
             rejection_stage: "pairing_code",
             rejection_reason: "invalid_structure"
           } = ScannerBoundaryProbe.diagnose(:code128, "casein://pair/not+base64url")

    assert %{
             scan_type: "other",
             byte_count: 0,
             compact_prefix?: false,
             base64url_segment?: false,
             rejection_stage: "pairing_code",
             rejection_reason: "invalid_structure"
           } = ScannerBoundaryProbe.diagnose({:untrusted, "value"}, :not_a_binary)

    assert %{rejection_reason: "invalid_encoding"} =
             ScannerBoundaryProbe.diagnose(:qr, <<255>>)
  end

  test "oversized values are capped and never inspected or logged" do
    sentinel = "NEVER_LOG_SCANNER_PROBE_PAYLOAD"
    value = "casein://pair/" <> String.duplicate("A", 4_097) <> sentinel
    pid = start_supervised!({ScannerBoundaryProbe, []})

    log =
      capture_log([level: :info], fn ->
        send(pid, {:scan, :result, %{type: :qr, value: value}})
        assert :ready = :sys.get_state(pid)
      end)

    assert log =~ "byte_count=4096"
    assert log =~ "compact_prefix=false"
    assert log =~ "base64url_segment=false"
    assert log =~ "rejection_stage=pairing_code rejection_reason=invalid_structure"
    refute log =~ sentinel
  end
end
