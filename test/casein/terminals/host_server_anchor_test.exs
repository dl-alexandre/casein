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

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)
end
