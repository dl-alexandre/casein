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

  # Stay on `baseline` for `after_reads` capture calls (baseline + polls), then
  # flip to `changed`. Used to model a TUI that only reacts after a second Enter.
  defp frozen_then_change(baseline, changed, opts) do
    after_reads = Keyword.fetch!(opts, :after_reads)
    key = {__MODULE__, :frozen_reads, System.unique_integer([:positive])}

    fn ->
      n = Process.get(key, 0) + 1
      Process.put(key, n)
      if n > after_reads, do: changed, else: baseline
    end
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
               PaneSubmit.confirm_submit(@session, @pane, capture: capture)

      assert result.submitted == true
      assert result.delivery == :delivered
      assert result.confirmation == :screen
      assert result.enter_presses == 1
      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _opts}
    end

    test "a frozen pane does not retry Enter and reports not_confirmed" do
      capture = scripted_capture(["> rebase first"])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane, capture: capture)

      assert result.submitted == false
      assert result.delivery == :not_confirmed
      assert result.confirmation == :unconfirmed
      assert result.enter_presses == 1

      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _first}
      refute_received {:fake_tmux_keys, @session, @pane, "Enter", _second}
    end

    test "strict callers get an error for the same frozen pane" do
      capture = scripted_capture(["> rebase first"])

      assert {:error, error} =
               PaneSubmit.confirm_submit(@session, @pane, capture: capture, strict: true)

      assert error.error == :submit_not_confirmed
      assert error.delivery == :not_confirmed
      assert error.message =~ "terminal_set_next_prompt"
    end

    test "trailing-whitespace-only redraws do not count as a change" do
      capture = scripted_capture(["> rebase first   ", "> rebase first"])

      assert {:ok, %{delivery: :not_confirmed}} =
               PaneSubmit.confirm_submit(@session, @pane, capture: capture)
    end

    test "OpenCode busy footer after Enter confirms even when prompt text remains" do
      # Baseline is the quiet composer with the paste already drained; after
      # Enter the footer flips to "esc interrupt" while the marker stays painted
      # in the transcript — the #886 false-negative shape.
      baseline =
        """
        ┃  CASEIN_886_BRIEF
        ┃
           Build · Grok 4.5 OpenCode Zen
         /data/casein-agent-worktrees/demo   ctrl+p commands
        """

      busy =
        """
        ┃  CASEIN_886_BRIEF
        ┃
           ▣  Build · Grok 4.5
           Build · Grok 4.5 OpenCode Zen
         ⬝⬝⬝⬝  esc interrupt                 ctrl+p commands
        """

      capture = scripted_capture([baseline, busy])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane, capture: capture)

      assert result.submitted == true
      assert result.delivery == :delivered
      assert result.confirmation == :screen
      assert result.enter_presses == 1
    end

    test "Braille spinner footer alone confirms a hook-less submit" do
      baseline = "> ready\n  Build · OpenCode"
      busy = "> ready\n  ⣿⣷  working…\n  Build · OpenCode"
      capture = scripted_capture([baseline, busy])

      assert {:ok, %{delivery: :delivered, enter_presses: 1}} =
               PaneSubmit.confirm_submit(@session, @pane, capture: capture)
    end

    test "an unreadable pane reports uncertain and never presses Enter twice" do
      capture = scripted_capture([""])

      assert {:ok, result} = PaneSubmit.confirm_submit(@session, @pane, capture: capture)

      assert result.delivery == :uncertain
      assert result.confirmation == :unavailable
      assert result.enter_presses == 1
    end

    test "enter_already_sent observes without pressing again" do
      capture = scripted_capture(["before", "after"])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane,
                 capture: capture,
                 enter_already_sent: true
               )

      assert result.delivery == :delivered
      assert result.enter_presses == 1
      refute_received {:fake_tmux_keys, @session, @pane, "Enter", _opts}
    end

    test "confirm: false short-circuits to skipped" do
      assert {:ok, result} = PaneSubmit.confirm_submit(@session, @pane, confirm: false)

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
               PaneSubmit.confirm_submit(@session, @pane,
                 capture: capture,
                 attempt_timeout_ms: 500,
                 poll_ms: 5
               )

      assert result.delivery == :delivered
      assert result.confirmation == :hook
    end

    test "a stale hook report from before the send does not confirm" do
      :ok = AgentState.report("ws-submit", @session, @pane, :working, "older turn", source: :hook)
      # Flush the cast so reported_at is committed, then wait until utc_now
      # is strictly after it so confirm_submit's `since` cannot equal the stamp.
      %{reported_at: at} = AgentState.get(@session, @pane)

      Casein.Test.Eventually.await(
        fn -> DateTime.compare(DateTime.utc_now(), at) == :gt end,
        timeout_ms: 50,
        interval_ms: 1,
        message: "utc_now did not advance past the stale hook report"
      )

      capture = scripted_capture(["> rebase first"])

      assert {:ok, %{delivery: :not_confirmed}} =
               PaneSubmit.confirm_submit(@session, @pane, capture: capture)
    end

    test "a dispatch-sourced report is Casein's own send and does not self-confirm" do
      frozen = scripted_capture(["> rebase first"])
      capture = report_on_second_call(frozen, :working, source: :dispatch)

      assert {:ok, %{delivery: :not_confirmed}} =
               PaneSubmit.confirm_submit(@session, @pane,
                 capture: capture,
                 attempt_timeout_ms: 50,
                 poll_ms: 5
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

  describe "confirm_submit/3 transcript signal" do
    test "a growing transcript confirms even on a frozen screen" do
      frozen = scripted_capture(["> rebase first"])
      capture = advance_transcript_on_second_call(frozen)

      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane, capture: capture)

      assert result.delivery == :delivered
      assert result.confirmation == :transcript
      assert result.enter_presses == 1
    end

    test "an injected transcript probe confirms without a file" do
      capture = scripted_capture(["> rebase first"])

      assert {:ok, result} =
               PaneSubmit.confirm_submit(@session, @pane,
                 capture: capture,
                 transcript: fn -> true end
               )

      assert result.delivery == :delivered
      assert result.confirmation == :transcript
    end
  end

  # Wraps a capture so the second read also grows a reported Claude transcript.
  defp advance_transcript_on_second_call(capture) do
    home = tmp_transcript_home!()
    path = claude_transcript!(home, "session-submit.jsonl", "")

    :ok =
      AgentState.report("ws-submit", @session, @pane, :idle, nil,
        source: :hook,
        transcript_path: path
      )

    _flush = AgentState.get(@session, @pane)
    key = {__MODULE__, :transcript_calls, System.unique_integer([:positive])}

    fn ->
      calls = Process.get(key, 0) + 1
      Process.put(key, calls)

      if calls == 2 do
        File.write!(path, ~s({"uuid":"u1","type":"user","message":{"content":"hi"}}\n))
      end

      capture.()
    end
  end

  defp claude_transcript!(home, name, body) do
    path = Path.join([home, ".claude", "projects", "demo", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp tmp_transcript_home! do
    root = System.get_env("CASEIN_TEST_TMPDIR") || System.tmp_dir!()
    home = Path.join(root, "casein-submit-transcripts-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("HOME")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)

      if previous_home,
        do: System.put_env("HOME", previous_home),
        else: System.delete_env("HOME")
    end)

    home
  end

  describe "deliver/4" do
    test "pastes the text and confirms the submit" do
      capture = scripted_capture(["idle", "⏺ thinking"])

      assert {:ok, result} =
               PaneSubmit.deliver(@session, @pane, "rebase onto master first", capture: capture)

      assert result.chunks_sent == 1
      assert result.delivery == :delivered
      assert_received {:fake_tmux_paste_text, @session, @pane, text, opts}
      assert text =~ "rebase onto master first"
      # Enter is this module's job, never the paste's: a submit folded into the
      # paste is exactly the race being defended against.
      refute Keyword.get(opts, :submit)
    end

    test "OpenCode-style race: unconfirmed after one Enter is submit_not_confirmed" do
      capture = frozen_then_change("> long brief", "⏺ working", after_reads: 12)

      assert {:error, result} =
               PaneSubmit.deliver(@session, @pane, "long fleet brief\nline 2\nline 3",
                 capture: capture,
                 settle_ms: 0,
                 retry_settle_ms: 0,
                 attempt_timeout_ms: 80,
                 poll_ms: 10
               )

      assert result.error == :submit_not_confirmed
      assert result.submitted == false
      assert result.delivery == :not_confirmed
      assert result.enter_presses == 1
      assert_received {:fake_tmux_paste_text, @session, @pane, _text, opts}
      refute Keyword.get(opts, :submit)
      assert_received {:fake_tmux_keys, @session, @pane, "Enter", _}
      refute_received {:fake_tmux_keys, @session, @pane, "Enter", _}
    end

    test "deliver scales settle from paste_bytes so large briefs drain first" do
      # Capture never changes — we only care that paste_bytes is forwarded and
      # settle is non-zero without blowing the test budget (capped).
      capture = scripted_capture(["> still here"])

      assert {:error, %{error: :submit_not_confirmed, enter_presses: 1}} =
               PaneSubmit.deliver(@session, @pane, String.duplicate("x", 400),
                 capture: capture,
                 # Explicit base 0; paste_bytes alone should still scale settle
                 # but retry stays 0 via test config / explicit override.
                 settle_ms: 0,
                 retry_settle_ms: 0,
                 paste_bytes: 400,
                 attempt_timeout_ms: 20,
                 poll_ms: 5
               )
    end

    test "an empty prompt sends nothing and never presses Enter" do
      assert {:ok, result} = PaneSubmit.deliver(@session, @pane, "   ")

      assert result.chunks_sent == 0
      assert result.delivery == :skipped
      refute_received {:fake_tmux_keys, @session, @pane, "Enter", _opts}
    end

    test "defaults to strict, so an unconfirmed submit is an error" do
      capture = scripted_capture(["idle"])

      assert {:error, error} =
               PaneSubmit.deliver(@session, @pane, "rebase first", capture: capture)

      assert error.error == :submit_not_confirmed
    end
  end
end
