defmodule Casein.Terminals.PaneSubmitTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.AgentState
  alias Casein.Terminals.PaneSubmit
  alias TmuxCtl.Test.FakeState

  @session "casein_alpha_submit"
  @pane "%7"

  setup do
    prev_test_pid = FakeState.get(:fake_tmux_test_pid)
    prev_adapter = Application.get_env(:casein, :tmux_adapter)

    FakeState.put(:fake_tmux_test_pid, self())
    Application.put_env(:casein, :tmux_adapter, TmuxCtl.Test.FakeAdapter)
    AgentState.clear()

    on_exit(fn ->
      AgentState.clear()
      FakeState.restore(:fake_tmux_test_pid, prev_test_pid)
      restore_app_env(:tmux_adapter, prev_adapter)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app_env(key, value), do: Application.put_env(:casein, key, value)

  # Production defaults settle ~400ms and wait for a stable screen. Unit tests
  # drive the capture frames themselves, so settle is always zeroed here.
  defp fast(opts \\ []) do
    Keyword.merge([settle_ms: 0, stable_timeout_ms: 0, stable_reads: 1], opts)
  end

  # A capture that yields each frame in turn and then repeats the last one,
  # standing in for a pane redrawing (or refusing to redraw) after Enter. State
  # lives in the process dictionary of whichever process runs the confirm loop —
  # only ever one — so this needs no process of its own.
  defp scripted_capture(frames) do
    key = {__MODULE__, :frames, System.unique_integer([:positive])}

    fn ->
      case Process.get(key, frames) do
        [last] ->
          Process.put(key, [last])
          last

        [head | tail] ->
          Process.put(key, tail)
          head

        [] ->
          ""
      end
    end
  end

  describe "confirm_submit/3 screen signal" do
    test "a pane that redraws after Enter is confirmed delivered" do
      capture = scripted_capture(["> rebase first", "⏺ working on it"])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane, fast(capture: capture))

      assert result.submitted == true
      assert result.delivery == :delivered
      assert result.confirmation == :screen
      assert result.enter_presses == 1
      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _opts}
    end

    test "a frozen pane gets exactly one retry Enter, then reports not_confirmed" do
      capture = scripted_capture(["> rebase first"])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane, fast(capture: capture))

      assert result.submitted == false
      assert result.delivery == :not_confirmed
      assert result.confirmation == :unconfirmed
      assert result.enter_presses == 2

      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _first}
      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _second}
      refute_received {:fake_tmux_keys, @session, @pane, "Enter", _third}
    end

    test "strict callers get an error for the same frozen pane" do
      capture = scripted_capture(["> rebase first"])

      assert {:error, error} =
               PaneSubmit.confirm_submit(
                 @session,
                 @pane,
                 fast(capture: capture, strict: true)
               )

      assert error.error == :submit_not_confirmed
      assert error.delivery == :not_confirmed
      assert error.message =~ "terminal_set_next_prompt"
    end

    test "trailing-whitespace-only redraws do not count as a change" do
      capture = scripted_capture(["> rebase first   ", "> rebase first"])

      assert {:ok, %{delivery: :not_confirmed}} =
               PaneSubmit.confirm_submit(@session, @pane, fast(capture: capture))
    end

    test "an unreadable pane reports uncertain and never presses Enter twice" do
      capture = scripted_capture([""])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane, fast(capture: capture))

      assert result.delivery == :uncertain
      assert result.confirmation == :unavailable
      assert result.enter_presses == 1
    end

    test "enter_already_sent observes without pressing again" do
      capture = scripted_capture(["before", "after"])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(
                 @session,
                 @pane,
                 fast(capture: capture, enter_already_sent: true)
               )

      assert result.delivery == :delivered
      assert result.enter_presses == 1
      refute_received {:fake_tmux_keys, @session, @pane, "Enter", _opts}
    end

    test "confirm: false short-circuits to skipped" do
      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane, fast(confirm: false))

      assert result.delivery == :skipped
      assert result.enter_presses == 0
      refute_received {:fake_tmux_keys, @session, @pane, "Enter", _opts}
    end
  end

  describe "confirm_submit/3 hook signal" do
    test "a fresh hook-sourced working report confirms even on a frozen screen" do
      # The report has to land *after* the confirm loop stamps its `since`, and
      # `since` is stamped after the baseline capture. Firing it from inside the
      # second capture call puts it on the right side of that line without a
      # sleep to race against.
      frozen = scripted_capture(["> rebase first"])
      capture = report_on_second_call(frozen, :working, source: :hook)

      assert {:ok, result} =
               PaneSubmit.confirm_submit(
                 @session,
                 @pane,
                 fast(capture: capture, attempt_timeout_ms: 500, poll_ms: 5)
               )

      assert result.delivery == :delivered
      assert result.confirmation == :hook
    end

    test "a stale hook report from before the send does not confirm" do
      :ok = AgentState.report("ws-submit", @session, @pane, :working, "older turn", source: :hook)
      # The store dedupes by timestamp, so wait out the resolution of utc_now/0
      # rather than racing it: the report must be strictly older than `since`.
      Process.sleep(5)
      capture = scripted_capture(["> rebase first"])

      assert {:ok, %{delivery: :not_confirmed}} =
               PaneSubmit.confirm_submit(@session, @pane, fast(capture: capture))
    end

    test "a dispatch-sourced report is Casein's own send and does not self-confirm" do
      frozen = scripted_capture(["> rebase first"])
      capture = report_on_second_call(frozen, :working, source: :dispatch)

      assert {:ok, %{delivery: :not_confirmed}} =
               PaneSubmit.confirm_submit(
                 @session,
                 @pane,
                 fast(capture: capture, attempt_timeout_ms: 50, poll_ms: 5)
               )
    end
  end

  # Wraps a capture so the Nth read also files an AgentState report, then reads
  # it back to flush the store's cast before the poll looks for it.
  defp report_on_second_call(capture, state, opts) do
    key = {__MODULE__, :calls, System.unique_integer([:positive])}

    fn ->
      calls = Process.get(key, 0) + 1
      Process.put(key, calls)

      if calls == 2 do
        :ok = AgentState.report("ws-submit", @session, @pane, state, "prompt accepted", opts)
        _flush = AgentState.get(@session, @pane)
      end

      capture.()
    end
  end

  describe "deliver/4" do
    test "pastes the text and confirms the submit" do
      capture = scripted_capture(["idle", "⏺ thinking"])

      assert {:ok, result} =
               PaneSubmit.deliver(
                 @session,
                 @pane,
                 "rebase onto master first",
                 fast(capture: capture)
               )

      assert result.chunks_sent == 1
      assert result.delivery == :delivered
      assert_received {:fake_tmux_paste_text, @session, @pane, text, opts}
      assert text =~ "rebase onto master first"
      # Enter is this module's job, never the paste's: a submit folded into the
      # paste is exactly the race being defended against.
      refute Keyword.get(opts, :submit)
    end

    test "OpenCode-style race: retry re-baselines so a failed first Enter cannot false-confirm" do
      # Sequence of captures:
      #   1. baseline (drained composer)
      #   2..n first-attempt polls (frozen — first Enter did nothing)
      #   n+1 rebaseline after first attempt fails (composer still drained, or
      #       with a newline from the failed press — either way, new baseline)
      #   n+2.. second-attempt polls flip to working after the second Enter
      #
      # If we did NOT re-baseline, a newline left by the first Enter would make
      # screen_changed? true on the second attempt without a real submit.
      capture =
        scripted_capture([
          # baseline
          "> long brief",
          # first-attempt polls (frozen)
          "> long brief",
          "> long brief",
          "> long brief",
          "> long brief",
          "> long brief",
          # rebaseline after failed first Enter (newline inserted — new baseline)
          "> long brief\n",
          "> long brief\n",
          # second-attempt polls — real submit redraw
          "⏺ working"
        ])

      assert {:ok, result} =
               PaneSubmit.deliver(
                 @session,
                 @pane,
                 "long fleet brief\nline 2\nline 3",
                 fast(
                   capture: capture,
                   attempt_timeout_ms: 30,
                   poll_ms: 5,
                   stable_reads: 1
                 )
               )

      assert result.submitted == true
      assert result.delivery == :delivered
      assert result.enter_presses == 2
      assert_received {:fake_tmux_paste_text, @session, @pane, _text, opts}
      refute Keyword.get(opts, :submit)
      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _}
      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _}
    end

    test "baseline is taken after settle so paste-drain redraws do not false-confirm" do
      # Frames: still-draining paste, then stable composer, then (after Enter)
      # the working marker. If baseline were taken before settle, the drain
      # step alone would look like a successful submit with zero Enter presses
      # pending — the #886 probe lie.
      capture =
        scripted_capture([
          "> brief…",
          "> fleet brief ready",
          "> fleet brief ready",
          "⏺ working"
        ])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(
                 @session,
                 @pane,
                 fast(
                   capture: capture,
                   stable_reads: 2,
                   stable_timeout_ms: 50,
                   poll_ms: 5,
                   attempt_timeout_ms: 200
                 )
               )

      assert result.submitted == true
      assert result.delivery == :delivered
      assert result.confirmation == :screen
      assert result.enter_presses == 1
      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _}
    end

    test "an empty prompt sends nothing and never presses Enter" do
      assert {:ok, result} = PaneSubmit.deliver(@session, @pane, "   ", fast())

      assert result.chunks_sent == 0
      assert result.delivery == :skipped
      refute_received {:fake_tmux_keys, @session, @pane, "Enter", _opts}
    end

    test "defaults to strict, so an unconfirmed submit is an error" do
      capture = scripted_capture(["idle"])

      assert {:error, error} =
               PaneSubmit.deliver(@session, @pane, "rebase first", fast(capture: capture))

      assert error.error == :submit_not_confirmed
    end
  end
end
