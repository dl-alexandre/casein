defmodule DevIDE.Previews.TidewaveProbeTest do
  use ExUnit.Case, async: true

  alias DevIDE.Previews.TidewaveProbe

  test "tidewave_response? accepts 2xx and 3xx status codes" do
    assert TidewaveProbe.tidewave_response?(200)
    assert TidewaveProbe.tidewave_response?(302)
    refute TidewaveProbe.tidewave_response?(404)
    refute TidewaveProbe.tidewave_response?(500)
    assert TidewaveProbe.tidewave_response?("200")
    refute TidewaveProbe.tidewave_response?("000")
    refute TidewaveProbe.tidewave_response?(:bad)
  end

  test "discover returns empty without a resolvable host path" do
    workspace = %{id: "no-path", metadata: %{}}
    assert TidewaveProbe.discover(workspace, [5173, 8765]) == []
  end

  test "discover never raises on invalid input" do
    assert TidewaveProbe.discover(%{}, "not-a-list") == []
    assert TidewaveProbe.probe_port(%{}, nil) == :missing
  end
end
