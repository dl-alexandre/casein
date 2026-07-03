defmodule DevIDE.Terminals.SessionTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals.{Session, Tmux}

  @moduletag :pty

  setup do
    cwd = System.tmp_dir!()
    sid = "t-" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
    workspace = "test-ws-" <> sid
    pty_available? = pty_available?(cwd)

    on_exit(fn -> Tmux.kill(Tmux.session_name(workspace, sid)) end)
    {:ok, workspace: workspace, sid: sid, cwd: cwd, pty_available?: pty_available?}
  end

  test "starts a tmux-backed PTY and streams output", ctx do
    with_pty(ctx, fn ->
      {:ok, pid} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      assert {:ok, _ref, cols, rows} = Session.subscribe(pid)
      assert cols > 0 and rows > 0

      # tmux paints the screen on attach — we just want to confirm bytes flow.
      output = collect_data(2_000)
      assert byte_size(output) > 0
      # tmux uses CSI escape sequences; this is a cheap sanity check.
      assert output =~ "\e["

      safe_stop(pid)
    end)
  end

  test "resuming an existing session brings the PTY up at the window's current width", ctx do
    with_pty(ctx, fn ->
      tmux_session = Tmux.session_name(ctx.workspace, ctx.sid)

      # First open creates the tmux session at the default size.
      {:ok, pid1} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      {:ok, _ref, _cols, _rows} = Session.subscribe(pid1)

      # The operator's viewport drives the window wider than the default. Force
      # it explicitly so the assertion is deterministic regardless of how tmux's
      # window-size policy tracks the (about-to-detach) client.
      wide_cols = 200
      wide_rows = 50
      :ok = Tmux.resize_window(tmux_session, wide_cols, wide_rows)
      assert {:ok, {^wide_cols, ^wide_rows}} = Tmux.window_size(tmux_session)

      # Drop the session process but leave the tmux session alive — this is a
      # resume (BEAM/page-reload cycle), not a kill.
      safe_stop(pid1)
      wait_until_stopped(pid1)

      # Reopen: the resumed session must report the window's real width, not the
      # hardcoded default — otherwise the terminal renders as a narrow column
      # with a blank gutter until a browser refit round-trips back up.
      {:ok, pid2} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      assert {:ok, _ref, cols, rows} = Session.subscribe(pid2)
      assert {cols, rows} == {wide_cols, wide_rows}

      safe_stop(pid2)
    end)
  end

  test "replays buffered output to a re-attaching subscriber", ctx do
    with_pty(ctx, fn ->
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
      Session.send_input(session_pid, "echo BEFORE_#{ctx.sid}\n")
      assert wait_for_session_output(session_pid, "BEFORE_#{ctx.sid}", 3_000)

      # Simulate browser disconnect: subscriber exits, Session keeps running.
      Process.exit(first, :kill)
      _ = :sys.get_state(session_pid)

      # More output arrives while no one is subscribed — this is the part
      # that proves the buffer is filled regardless of attach state.
      Session.send_input(session_pid, "echo AFTER_#{ctx.sid}\n")
      assert wait_for_session_output(session_pid, "AFTER_#{ctx.sid}", 3_000)

      # Reattach from the test process. Replay should arrive immediately.
      {:ok, _ref, _cols, _rows} = Session.subscribe(session_pid)
      output = collect_data(1_500)

      assert output =~ "BEFORE_",
             "expected pre-disconnect output in replay; got: #{inspect(output)}"

      assert output =~ "AFTER_",
             "expected post-disconnect output in replay (proves buffering without subscriber); got: #{inspect(output)}"

      safe_stop(session_pid)
    end)
  end

  test "recovers tmux scrollback when the Session GenServer is rebuilt", ctx do
    with_pty(ctx, fn ->
      # First Session: drive output that should land in tmux's scrollback.
      {:ok, pid1} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      {:ok, _ref, _cols, _rows} = Session.subscribe(pid1)
      Session.send_input(pid1, "echo SCROLLBACK_MARK_#{ctx.sid}\n")
      _ = collect_data(1_200)

      # Stop the Session GenServer but leave the tmux session running —
      # this simulates a BEAM restart while tmux persists (the very case
      # audit_remote.md CC-3 calls out).
      safe_stop(pid1)
      wait_until_stopped(pid1)

      # New Session for the same (workspace, sid). On init, this should
      # capture the existing tmux pane's scrollback and seed the buffer
      # so the first subscriber sees the history immediately.
      {:ok, pid2} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      {:ok, _ref, _cols, _rows} = Session.subscribe(pid2)
      output = collect_data(1_500)

      assert output =~ "SCROLLBACK_MARK_",
             "expected captured scrollback to replay on the new Session; got: #{inspect(output)}"

      safe_stop(pid2)
    end)
  end

  test "ensure_started reattaches to an existing tmux session across restarts", ctx do
    with_pty(ctx, fn ->
      {:ok, pid1} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      {:ok, _, _, _} = Session.subscribe(pid1)
      Session.send_input(pid1, "echo MARKER_$$ > /tmp/pty_marker_#{ctx.sid}\n")
      _ = collect_data(1_000)
      safe_stop(pid1)
      wait_until_stopped(pid1)

      {:ok, pid2} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      {:ok, _, _, _} = Session.subscribe(pid2)
      Session.send_input(pid2, "cat /tmp/pty_marker_#{ctx.sid}\n")
      output = collect_data(2_000)
      assert output =~ "MARKER_"

      safe_stop(pid2)
      File.rm("/tmp/pty_marker_#{ctx.sid}")
    end)
  end

  test "new tmux sessions start with default terminal theme environment", ctx do
    with_pty(ctx, fn ->
      tmux_session = Tmux.session_name(ctx.workspace, ctx.sid)

      {:ok, pid} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      assert {:ok, _, _, _} = Session.subscribe(pid)

      assert {:ok, "DEV_IDE_TERMINAL_SCHEME=dark"} =
               tmux_show_environment(tmux_session, "DEV_IDE_TERMINAL_SCHEME")

      assert {:ok, "DEV_IDE_TERMINAL_PRESET=catppuccin"} =
               tmux_show_environment(tmux_session, "DEV_IDE_TERMINAL_PRESET")

      assert {:ok, "COLORFGBG=15;0"} = tmux_show_environment(tmux_session, "COLORFGBG")

      safe_stop(pid)
    end)
  end

  defp with_pty(%{pty_available?: true}, fun), do: fun.()
  defp with_pty(%{pty_available?: false}, _fun), do: assert(true)

  defp pty_available?(cwd) do
    sid = "probe-" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
    workspace = "pty-probe-" <> sid
    tmux_session = Tmux.session_name(workspace, sid)

    try do
      case Session.ensure_started(workspace, sid, cwd) do
        {:ok, pid} ->
          available? =
            case safe_subscribe(pid) do
              {:ok, _ref, _cols, _rows} -> true
              :pty_unavailable -> false
            end

          safe_stop(pid)
          available?

        {:error, _reason} ->
          false
      end
    after
      Tmux.kill(tmux_session)
    end
  end

  test "fans out to multiple subscribers without disconnecting earlier ones", ctx do
    with_pty(ctx, fn ->
      {:ok, session_pid} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)
      parent = self()

      # First subscriber (proxy process).
      first =
        spawn_link(fn ->
          {:ok, _ref, _, _} = Session.subscribe(session_pid)
          send(parent, :first_subscribed)
          relay_term_data(parent, :first)
        end)

      assert_receive :first_subscribed, 2_000

      # Second subscriber attaches while the first is still live. Pre-fix,
      # this would silently disconnect `first`. Now both must keep receiving.
      second =
        spawn_link(fn ->
          {:ok, _ref, _, _} = Session.subscribe(session_pid)
          send(parent, :second_subscribed)
          relay_term_data(parent, :second)
        end)

      assert_receive :second_subscribed, 2_000

      # Drive output and confirm both subscribers see it.
      Session.send_input(session_pid, "echo MULTI_#{ctx.sid}\n")

      first_saw_marker? = wait_for_marker(:first, "MULTI_#{ctx.sid}", 5_000)
      second_saw_marker? = wait_for_marker(:second, "MULTI_#{ctx.sid}", 5_000)

      assert first_saw_marker?, "first subscriber must still receive output after second joined"
      assert second_saw_marker?, "second subscriber must receive output"

      Process.exit(first, :kill)
      Process.exit(second, :kill)
      safe_stop(session_pid)
    end)
  end

  test "snapshot/1 returns the retained buffer without subscribing", ctx do
    with_pty(ctx, fn ->
      {:ok, pid} = Session.ensure_started(ctx.workspace, ctx.sid, ctx.cwd)

      # Subscribe to drive the buffer, then unsubscribe so we can verify that
      # snapshot/1 doesn't depend on having a live subscriber.
      {:ok, _ref, _, _} = Session.subscribe(pid)
      Session.send_input(pid, "echo SNAP_#{ctx.sid}\n")
      _ = collect_data(2_000)
      :ok = Session.unsubscribe(pid)

      buf = Session.snapshot(pid)
      assert is_binary(buf)
      assert byte_size(buf) > 0

      safe_stop(pid)
    end)
  end

  defp relay_term_data(parent, tag) do
    receive do
      {:term_data, _ref, data} ->
        send(parent, {tag, IO.iodata_to_binary(data)})
        relay_term_data(parent, tag)
    end
  end

  defp wait_for_marker(tag, marker, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_marker(tag, marker, "", deadline)
  end

  defp do_wait_for_marker(tag, marker, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      acc =~ marker ->
        true

      remaining <= 0 ->
        false

      true ->
        receive do
          {^tag, chunk} -> do_wait_for_marker(tag, marker, acc <> chunk, deadline)
        after
          remaining -> acc =~ marker
        end
    end
  end

  defp safe_subscribe(pid) do
    Session.subscribe(pid)
  catch
    :exit, _ -> :pty_unavailable
  end

  defp safe_stop(pid) do
    Session.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp wait_until_stopped(pid, attempts \\ 50) do
    if Process.alive?(pid) do
      if attempts <= 0 do
        flunk("session process did not stop in time")
      else
        receive do
        after
          10 -> wait_until_stopped(pid, attempts - 1)
        end
      end
    else
      :ok
    end
  end

  defp wait_for_session_output(session_pid, marker, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_session_output(session_pid, marker, deadline)
  end

  defp do_wait_for_session_output(session_pid, marker, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        false

      snapshot_contains?(session_pid, marker) ->
        true

      true ->
        receive do
        after
          min(remaining, 50) ->
            do_wait_for_session_output(session_pid, marker, deadline)
        end
    end
  end

  defp snapshot_contains?(session_pid, marker) do
    case Session.snapshot(session_pid) do
      buf when is_binary(buf) -> String.contains?(buf, marker)
      _ -> false
    end
  end

  defp collect_data(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect("", deadline)
  end

  defp tmux_show_environment(session, key) do
    case DevIDE.Terminals.TmuxRunner.run(["show-environment", "-t", session, key]) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, out}}
    end
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
