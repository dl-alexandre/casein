defmodule Casein.Access.DoctorTest do
  use ExUnit.Case, async: true

  alias Casein.Access.Endpoint
  alias Casein.Access.Endpoints

  test "doctor output shape lists kind, url, and liveness" do
    lines =
      Endpoints.doctor_lines([
        {Endpoint.loopback("http://127.0.0.1:4000"), true},
        {Endpoint.lan("http://studio.local"), false},
        {Endpoint.public_https("https://casein.example.com"), true}
      ])

    joined = Enum.join(lines, "\n")
    assert joined =~ "Access endpoints"
    assert joined =~ "loopback"
    assert joined =~ "http://127.0.0.1:4000"
    assert joined =~ "alive"
    assert joined =~ "lan"
    assert joined =~ "dead"
    assert joined =~ "public_https"
    assert joined =~ "scope=any"
  end

  test "doctor output shape handles empty inventory" do
    lines = Endpoints.doctor_lines([])
    joined = Enum.join(lines, "\n")
    assert joined =~ "Access endpoints"
    assert joined =~ "none advertised"
  end
end
