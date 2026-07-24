defmodule TmuxCtl.Events.ControlListenerTmuxTest do
  @moduledoc """
  Real-tmux integration for ControlListener on the sandboxed `-L devide_test`
  server. Excluded by default (`@moduletag :tmux`); run with `mix test --include tmux`.
  """

  use ExUnit.Case, async: false

  @moduletag :tmux

  alias TmuxCtl.Events.ControlListener
  alias DevIDE.Test.Eventually

  @label "devide_test"
  @anchor "__devide_keepalive"
  @topic "tmux_events:" <> @label

  setup do
    tmux = System.find_executable("tmux") || flunk("tmux not on PATH")

    # Isolate: kill any prior sandbox server, recreate anchor.
    _ = System.cmd(tmux, ["-L", @label, "kill-server"], stderr_to_stdout: true)
    # Wait until the sandbox server is fully gone before recreating.
    Eventually.await(
      fn ->
        match?(
          {_, code} when code != 0,
          System.cmd(tmux, ["-L", @label, "list-sessions"], stderr_to_stdout: true)
        )
      end,
      timeout_ms: 2000
    )

    {_, 0} =
      System.cmd(
        tmux,
        ["-L", @label, "new-session", "-d", "-s", @anchor],
        stderr_to_stdout: true
      )

    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, @topic)

    name = :"control_listener_tmux_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised(
        {ControlListener,
         [
           label: @label,
           pubsub: DevIDE.PubSub,
           tmux_bin: tmux,
           anchor_session: @anchor,
           name: name,
           backoff_ms: [200, 400, 800]
         ]}
      )

    on_exit(fn ->
      _ = System.cmd(tmux, ["-L", @label, "kill-server"], stderr_to_stdout: true)
    end)

    %{tmux: tmux, listener: pid, name: name}
  end

  test "emits topology notifications for new/rename/kill window", %{tmux: tmux} do
    assert_receive {TmuxCtl.Events, {:listener_up, @label}}, 3_000

    {_, 0} =
      System.cmd(
        tmux,
        ["-L", @label, "new-window", "-t", @anchor, "-n", "evt-win"],
        stderr_to_stdout: true
      )

    assert_receive {TmuxCtl.Events, {:tmux_event, %{type: type}}}
                   when type in [:window_add, :session_window_changed, :layout_change],
                   3_000

    # Rename the newly created window (index 1 after keepalive's initial window).
    {_, 0} =
      System.cmd(
        tmux,
        ["-L", @label, "rename-window", "-t", "#{@anchor}:1", "renamed-evt"],
        stderr_to_stdout: true
      )

    assert_receive {TmuxCtl.Events, {:tmux_event, %{type: :window_renamed}}}, 3_000

    {_, 0} =
      System.cmd(
        tmux,
        ["-L", @label, "kill-window", "-t", "#{@anchor}:1"],
        stderr_to_stdout: true
      )

    assert_receive {TmuxCtl.Events, {:tmux_event, %{type: type}}}
                   when type in [:window_close, :session_window_changed, :layout_change],
                   3_000
  end

  test "kill-server yields listener_down; recreate yields listener_up", %{tmux: tmux} do
    assert_receive {TmuxCtl.Events, {:listener_up, @label}}, 3_000

    {_, _} = System.cmd(tmux, ["-L", @label, "kill-server"], stderr_to_stdout: true)

    assert_receive {TmuxCtl.Events, {:listener_down, @label}}, 3_000

    # Recreate server + anchor; backoff should reconnect.
    # Wait until the sandbox server is fully gone before recreating.
    Eventually.await(
      fn ->
        match?(
          {_, code} when code != 0,
          System.cmd(tmux, ["-L", @label, "list-sessions"], stderr_to_stdout: true)
        )
      end,
      timeout_ms: 2000
    )

    {_, 0} =
      System.cmd(
        tmux,
        ["-L", @label, "new-session", "-d", "-s", @anchor],
        stderr_to_stdout: true
      )

    assert_receive {TmuxCtl.Events, {:listener_up, @label}}, 5_000
  end
end
