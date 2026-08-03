defmodule Casein.Terminals.HostServerAnchorTest do
  # async: false — toggles :casein app env (tmux_host_anchor / tmux_server_label).
  use ExUnit.Case, async: false

  alias Casein.Terminals.HostServerAnchor

  describe "stable_dir/2" do
    test "returns the first candidate directory that exists" do
      exists? = fn d -> d == "/opt/casein" end
      assert HostServerAnchor.stable_dir(["/opt/casein", "/"], exists?) == "/opt/casein"
    end

    test "skips missing candidates and picks the next existing one" do
      exists? = fn d -> d == "/" end
      assert HostServerAnchor.stable_dir(["/opt/casein", "/"], exists?) == "/"
    end

    test "falls back to $HOME when no candidate exists" do
      prev = System.get_env("HOME")
      System.put_env("HOME", "/home/tester")

      on_exit(fn ->
        if prev, do: System.put_env("HOME", prev), else: System.delete_env("HOME")
      end)

      exists? = fn d -> d == "/home/tester" end
      assert HostServerAnchor.stable_dir(["/opt/casein"], exists?) == "/home/tester"
    end

    test "falls back to / when nothing (not even $HOME) exists" do
      assert HostServerAnchor.stable_dir(["/opt/casein"], fn _ -> false end) == "/"
    end
  end

  describe "enabled?/0" do
    setup do
      prev_flag = Application.get_env(:casein, :tmux_host_anchor)
      prev_label = Application.get_env(:casein, :tmux_server_label)

      on_exit(fn ->
        restore(:tmux_host_anchor, prev_flag)
        restore(:tmux_server_label, prev_label)
      end)

      :ok
    end

    test "false when the flag is disabled even if a label is set" do
      Application.put_env(:casein, :tmux_host_anchor, false)
      Application.put_env(:casein, :tmux_server_label, "casein_test")
      refute HostServerAnchor.enabled?()
    end

    test "false when no host server label is configured" do
      Application.put_env(:casein, :tmux_host_anchor, true)
      Application.delete_env(:casein, :tmux_server_label)
      refute HostServerAnchor.enabled?()
    end

    test "true when enabled and a host label is configured" do
      Application.put_env(:casein, :tmux_host_anchor, true)
      Application.put_env(:casein, :tmux_server_label, "casein")
      assert HostServerAnchor.enabled?()
    end
  end

  describe "ensure!/0" do
    test "is a no-op that returns :ok when disabled (test config)" do
      # config/test.exs sets tmux_host_anchor false, so this must not shell out.
      refute HostServerAnchor.enabled?()
      assert HostServerAnchor.ensure!() == :ok
    end
  end

  describe "stale_socket_failure?/1" do
    test "true for the orphaned-socket signature tmux emits" do
      assert HostServerAnchor.stale_socket_failure?("server exited unexpectedly")
    end

    test "true regardless of case or surrounding output" do
      assert HostServerAnchor.stale_socket_failure?("error: Server Exited Unexpectedly\n")
    end

    test "false for unrelated tmux failures" do
      refute HostServerAnchor.stale_socket_failure?("duplicate session: __casein_keepalive")
      refute HostServerAnchor.stale_socket_failure?("no server running on /tmp/tmux-1001/casein")
      refute HostServerAnchor.stale_socket_failure?("")
    end

    test "false for non-binary output" do
      refute HostServerAnchor.stale_socket_failure?(nil)
    end
  end

  describe "socket_path/3" do
    test "defaults to /tmp/tmux-<uid>/<label>" do
      assert HostServerAnchor.socket_path("casein", nil, "1001") == "/tmp/tmux-1001/casein"
    end

    test "honors TMUX_TMPDIR, still appending tmux-<uid>" do
      assert HostServerAnchor.socket_path("casein", "/run/tmux", "1001") ==
               "/run/tmux/tmux-1001/casein"
    end

    test "treats an empty TMUX_TMPDIR as unset" do
      assert HostServerAnchor.socket_path("casein", "", "1001") == "/tmp/tmux-1001/casein"
    end

    test "nil for the default (unlabeled) server so its socket is never removed" do
      assert HostServerAnchor.socket_path(nil, nil, "1001") == nil
      assert HostServerAnchor.socket_path("", nil, "1001") == nil
    end

    test "nil when the uid could not be resolved" do
      assert HostServerAnchor.socket_path("casein", nil, nil) == nil
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)
end
