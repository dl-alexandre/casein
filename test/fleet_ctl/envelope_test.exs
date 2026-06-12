defmodule FleetCtl.EnvelopeTest do
  use ExUnit.Case, async: true

  alias FleetCtl.Envelope

  test "valid_uuid? accepts canonical UUIDs" do
    assert Envelope.valid_uuid?("550e8400-e29b-41d4-a716-446655440000")
    refute Envelope.valid_uuid?("not-a-uuid")
    refute Envelope.valid_uuid?(nil)
  end

  test "valid_datetime? accepts DateTime structs only" do
    assert Envelope.valid_datetime?(DateTime.utc_now())
    refute Envelope.valid_datetime?("2026-01-01T00:00:00Z")
  end
end
