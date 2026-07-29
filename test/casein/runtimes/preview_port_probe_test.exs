defmodule Casein.Runtimes.PreviewPortProbeTest do
  use ExUnit.Case, async: true

  alias Casein.Runtimes.PreviewPortProbe

  test "reports a loopback listener as unavailable" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    refute PreviewPortProbe.available?(port)
  end

  test "reports a released loopback port as available" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    assert PreviewPortProbe.available?(port)
  end

  test "rejects invalid ports" do
    refute PreviewPortProbe.available?(nil)
    refute PreviewPortProbe.available?(0)
    refute PreviewPortProbe.available?(65_536)
  end
end
