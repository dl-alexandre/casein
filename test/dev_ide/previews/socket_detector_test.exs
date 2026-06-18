defmodule DevIDE.Previews.SocketDetectorTest do
  use ExUnit.Case, async: true

  alias DevIDE.Previews.SocketDetector

  describe "parse_ports/1" do
    test "parses headerless `ss -Htln` output" do
      output = """
      LISTEN 0      511          0.0.0.0:3000       0.0.0.0:*
      LISTEN 0      511             [::]:3000          [::]:*
      LISTEN 0      128          0.0.0.0:5173       0.0.0.0:*
      """

      assert SocketDetector.parse_ports(output) |> Enum.sort() |> Enum.uniq() == [3000, 5173]
    end

    test "parses `ss -ltn` output with a header line" do
      output = """
      State  Recv-Q Send-Q Local Address:Port Peer Address:Port
      LISTEN 0      4096        127.0.0.1:4000      0.0.0.0:*
      LISTEN 0      4096        127.0.0.1:5432      0.0.0.0:*
      """

      # 5432 is left in by the parser; deny-listing happens in discover_ports/1.
      assert SocketDetector.parse_ports(output) |> Enum.sort() == [4000, 5432]
    end

    test "parses `lsof` LISTEN lines and ignores other lines" do
      output = """
      COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
      node     1234 dev    23u  IPv4  98765      0t0  TCP *:8080 (LISTEN)
      node     1234 dev    24u  IPv6  98766      0t0  TCP [::1]:8081 (LISTEN)
      node     1234 dev    25u  IPv4  98767      0t0  TCP 1.2.3.4:55000->5.6.7.8:443 (ESTABLISHED)
      """

      assert SocketDetector.parse_ports(output) |> Enum.sort() == [8080, 8081]
    end

    test "ignores single-digit and out-of-range numbers" do
      # `:1` (loopback ::1 fragment) is one digit -> not matched; 99999 is filtered.
      output = "LISTEN 0 0 [::1]:99999 [::]:*\n"
      assert SocketDetector.parse_ports(output) == []
    end

    test "returns [] for non-listening / empty input" do
      assert SocketDetector.parse_ports("") == []
      assert SocketDetector.parse_ports("nothing here\n") == []
      assert SocketDetector.parse_ports(nil) == []
    end
  end

  describe "discover_ports/1" do
    test "returns [] when the workspace has no resolvable host path" do
      assert SocketDetector.discover_ports(%{id: "no-path", metadata: %{}}) == []
    end

    test "returns [] for non-map input" do
      assert SocketDetector.discover_ports(nil) == []
    end
  end
end
