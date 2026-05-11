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

  test "replays buffered output to a re-attaching subscriber", ctx do
    {:ok, session_pid} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)

    # First subscriber: spawned process we'll kill to simulate disconnect.
    parent = self()

    first =
      spawn(fn ->
        {:ok, _ref, _cols, _rows} = Session.subscribe(session_pid)
        send(parent, :subscribed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :subscribed, 1_000

    # Drive output through tmux while the first subscriber is attached.
    Session.input(session_pid, "echo BEFORE_#{ctx.sid}\n")
    Process.sleep(800)

    # Simulate browser disconnect: subscriber exits, Session keeps running.
    Process.exit(first, :kill)
    Process.sleep(200)

    # More output arrives while no one is subscribed — this is the part
    # that proves the buffer is filled regardless of attach state.
    Session.input(session_pid, "echo AFTER_#{ctx.sid}\n")
    Process.sleep(800)

    # Reattach from the test process. Replay should arrive immediately.
    {:ok, _ref, _cols, _rows} = Session.subscribe(session_pid)
    output = collect_data(1_500)

    assert output =~ "BEFORE_",
           "expected pre-disconnect output in replay; got: #{inspect(output)}"

    assert output =~ "AFTER_",
           "expected post-disconnect output in replay (proves buffering without subscriber); got: #{inspect(output)}"

    Session.stop(session_pid)
  end

  test "recovers tmux scrollback when the Session GenServer is rebuilt", ctx do
    # First Session: drive output that should land in tmux's scrollback.
    {:ok, pid1} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
    {:ok, _ref, _cols, _rows} = Session.subscribe(pid1)
    Session.input(pid1, "echo SCROLLBACK_MARK_#{ctx.sid}\n")
    _ = collect_data(1_200)

    # Stop the Session GenServer but leave the tmux session running —
    # this simulates a BEAM restart while tmux persists (the very case
    # audit_remote.md CC-3 calls out).
    Session.stop(pid1)
    Process.sleep(300)

    # New Session for the same (workspace, sid). On init, this should
    # capture the existing tmux pane's scrollback and seed the buffer
    # so the first subscriber sees the history immediately.
    {:ok, pid2} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
    {:ok, _ref, _cols, _rows} = Session.subscribe(pid2)
    output = collect_data(1_500)

    assert output =~ "SCROLLBACK_MARK_",
           "expected captured scrollback to replay on the new Session; got: #{inspect(output)}"

    Session.stop(pid2)
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
