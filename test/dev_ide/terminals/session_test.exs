defmodule DevIDE.Terminals.SessionTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.{Session, Tmux}

  @moduletag :pty

  setup do
    cwd = System.tmp_dir!()
    sid = "t-" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
    workspace = "test-ws-" <> sid

    on_exit(fn -> Tmux.kill(Tmux.session_name(workspace, sid)) end)
    {:ok, workspace: workspace, sid: sid, cwd: cwd}
  end

  test "starts a tmux-backed PTY and streams output", ctx do
    {:ok, pid} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
    assert {:ok, _ref, cols, rows} = Session.subscribe(pid)
    assert cols > 0 and rows > 0

    # tmux paints the screen on attach — we just want to confirm bytes flow.
    output = collect_data(2_000)
    assert byte_size(output) > 0
    # tmux uses CSI escape sequences; this is a cheap sanity check.
    assert output =~ "\e["

    Session.stop(pid)
  end

  test "ensure_started reattaches to an existing tmux session across restarts", ctx do
    {:ok, pid1} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
    {:ok, _, _, _} = Session.subscribe(pid1)
    Session.input(pid1, "echo MARKER_$$ > /tmp/pty_marker_#{ctx.sid}\n")
    _ = collect_data(1_000)
    Session.stop(pid1)
    :timer.sleep(200)

    {:ok, pid2} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
    {:ok, _, _, _} = Session.subscribe(pid2)
    Session.input(pid2, "cat /tmp/pty_marker_#{ctx.sid}\n")
    output = collect_data(2_000)
    assert output =~ "MARKER_"

    Session.stop(pid2)
    File.rm("/tmp/pty_marker_#{ctx.sid}")
  end

  defp collect_data(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect("", deadline)
  end

  defp do_collect(acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      receive do
        {:term_data, _ref, data} -> do_collect(acc <> IO.iodata_to_binary(data), deadline)
      after
        remaining -> acc
      end
    end
  end
end
