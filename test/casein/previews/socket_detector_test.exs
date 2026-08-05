defmodule Casein.Previews.SocketDetectorTest do
  use Casein.TestCase, async: true

  alias Casein.Previews.SocketDetector

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

  describe "probe_argv/1" do
    test "attached folders probe host sockets directly" do
      workspace = %{metadata: %{attached_folder: true}}

      assert ["sh", "-c", probe] = SocketDetector.probe_argv(workspace)
      assert probe =~ "ss -Htlnp"
    end
  end

  describe "ports_for_workspace_cwd/3" do
    test "keeps listening sockets owned by processes inside the workspace" do
      output = """
      LISTEN 0 1024 0.0.0.0:41330 0.0.0.0:* users:(("beam.smp",pid=123,fd=33))
      LISTEN 0 1024 0.0.0.0:41000 0.0.0.0:* users:(("node",pid=456,fd=12))
      LISTEN 0 4096 127.0.0.1:4000 0.0.0.0:*
      """

      read_cwd = fn
        123 -> "/data/workspaces/demo/apps/web"
        456 -> "/data/workspaces/other"
      end

      assert SocketDetector.ports_for_workspace_cwd(output, "/data/workspaces/demo", read_cwd) ==
               [41_330]
    end
  end

  describe "ports_under_roots/3" do
    # The real shape on the devbox: the workspace is /data/workspaces/<name>, but
    # agents run their dev servers in /data/casein-agent-worktrees/<id>, a
    # sibling. Scoping to the workspace path alone returned [] here, so detection
    # fell back to regexing the banner out of tmux scrollback.
    @output """
    LISTEN 0 1024 0.0.0.0:4003 0.0.0.0:* users:(("beam.smp",pid=123,fd=33))
    LISTEN 0 1024 0.0.0.0:21005 0.0.0.0:* users:(("beam.smp",pid=456,fd=12))
    LISTEN 0 1024 0.0.0.0:9999 0.0.0.0:* users:(("beam.smp",pid=789,fd=9))
    """

    defp read_cwd do
      fn
        123 -> "/data/casein-agent-worktrees/agent-claude-adhoc-1"
        456 -> "/data/workspaces/mine/apps/web"
        789 -> "/data/casein-agent-worktrees/agent-claude-adhoc-PEER"
      end
    end

    test "finds a dev server running in the workspace's own agent worktree" do
      roots = ["/data/workspaces/mine", "/data/casein-agent-worktrees/agent-claude-adhoc-1"]

      assert SocketDetector.ports_under_roots(@output, roots, read_cwd()) == [4003, 21_005]
    end

    # The isolation property. Worktree *roots* are global, so anything keyed off
    # a root rather than per-workspace attribution would hand one workspace its
    # peer's dev-server ports.
    test "never claims a peer workspace's agent worktree" do
      roots = ["/data/workspaces/mine", "/data/casein-agent-worktrees/agent-claude-adhoc-1"]

      refute 9999 in SocketDetector.ports_under_roots(@output, roots, read_cwd())
    end

    test "without worktree roots it sees only the workspace itself" do
      assert SocketDetector.ports_under_roots(@output, ["/data/workspaces/mine"], read_cwd()) ==
               [21_005]
    end

    test "ignores blank and non-binary roots, and yields nothing when all are dropped" do
      assert SocketDetector.ports_under_roots(@output, ["", nil, :bad], read_cwd()) == []
      assert SocketDetector.ports_under_roots(@output, [], read_cwd()) == []
    end

    test "a sibling path that merely shares a prefix is not inside the root" do
      read = fn 123 -> "/data/workspaces/mine-other/apps" end

      line = ~s|LISTEN 0 1024 0.0.0.0:4003 0.0.0.0:* users:(("beam.smp",pid=123,fd=33))|

      assert SocketDetector.ports_under_roots(line, ["/data/workspaces/mine"], read) == []
    end
  end
end
