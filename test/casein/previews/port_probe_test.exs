defmodule Casein.Previews.PortProbeTest do
  use ExUnit.Case, async: true

  alias Casein.Previews.PortProbe

  test "alive? is true for a listening loopback port and false after it closes" do
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, port} = :inet.port(listener)

    assert PortProbe.alive?(port)

    :ok = :gen_tcp.close(listener)
    refute PortProbe.alive?(port)
  end

  test "alive? rejects out-of-range and non-integer ports" do
    refute PortProbe.alive?(0)
    refute PortProbe.alive?(-1)
    refute PortProbe.alive?(70_000)
    refute PortProbe.alive?("4000")
    refute PortProbe.alive?(nil)
  end

  test "probe maps unique integer ports to liveness and drops junk" do
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, open_port} = :inet.port(listener)

    {:ok, closed_listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, closed_port} = :inet.port(closed_listener)
    :ok = :gen_tcp.close(closed_listener)

    assert PortProbe.probe([open_port, closed_port, open_port, "4000", nil]) ==
             %{open_port => true, closed_port => false}

    :ok = :gen_tcp.close(listener)
  end
end
