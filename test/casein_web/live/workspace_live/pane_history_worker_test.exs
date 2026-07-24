defmodule CaseinWeb.WorkspaceLive.PaneHistoryWorkerTest do
  use ExUnit.Case, async: true

  alias CaseinWeb.WorkspaceLive.PaneHistoryWorker

  defmodule StubTmux do
    def capture_scrollback(session, opts) do
      case Process.whereis(:pane_history_worker_test_capture) do
        nil -> :ok
        pid -> send(pid, {:captured, session, opts})
      end

      Enum.map_join(1..40, "\n", &line/1) <> "\n"
    end

    def line(n), do: "history-line-" <> String.pad_leading(Integer.to_string(n), 3, "0")
  end

  defmodule EmptyTmux do
    def capture_scrollback(_session, _opts), do: ""
  end

  test "seeds a scrollable emulator from the targeted pane's tmux history" do
    Process.register(self(), :pane_history_worker_test_capture)

    {:ok, worker} =
      PaneHistoryWorker.start_link(
        parent: self(),
        pane_id: "%7",
        tmux_session: "devide_ws_s1",
        cols: 40,
        rows: 10,
        tmux_adapter: StubTmux
      )

    assert_receive {:pane_history_ready, "%7", term}

    # The capture targets the specific pane (not the session's active pane),
    # keeps ANSI colors, and is tailed to what the emulator can retain.
    assert_receive {:captured, "devide_ws_s1", opts}
    assert opts[:target] == "%7"
    assert opts[:ansi] == true
    assert is_integer(opts[:lines]) and opts[:lines] > 0

    # Older lines landed in scrollback, the newest at the viewport bottom.
    %{total: total, len: len, offset: offset} = Ghostty.Terminal.scrollbar(term)
    assert total > len
    assert offset == total - len

    {:ok, snapshot} = Ghostty.Terminal.snapshot(term, :plain)
    assert snapshot =~ StubTmux.line(40)

    # CRLF normalization: capture-pane joins lines with bare "\n"; without the
    # CR every line would staircase rightward. Every rendered row must start
    # at column 0.
    for row <- Ghostty.Terminal.cells(term),
        [{char, _fg, _bg, _flags} | _] = row,
        char not in ["", " ", nil] do
      assert char == "h", "expected row to start at column 0, got #{inspect(char)}"
    end

    # The viewport scrolls back through the captured history.
    :ok = Ghostty.Terminal.scroll(term, -total)
    %{offset: scrolled} = Ghostty.Terminal.scrollbar(term)
    assert scrolled == 0

    PaneHistoryWorker.stop(worker)
  end

  test "an empty capture still reports ready with a blank viewer" do
    {:ok, worker} =
      PaneHistoryWorker.start_link(
        parent: self(),
        pane_id: "%1",
        tmux_session: "devide_ws_s1",
        cols: 20,
        rows: 5,
        tmux_adapter: EmptyTmux
      )

    assert_receive {:pane_history_ready, "%1", term}

    %{total: total, len: len} = Ghostty.Terminal.scrollbar(term)
    assert total == len

    PaneHistoryWorker.stop(worker)
  end

  test "stop tears down the emulator instead of leaking it" do
    {:ok, worker} =
      PaneHistoryWorker.start_link(
        parent: self(),
        pane_id: "%3",
        tmux_session: "devide_ws_s1",
        cols: 20,
        rows: 5,
        tmux_adapter: EmptyTmux
      )

    assert_receive {:pane_history_ready, "%3", term}

    ref = Process.monitor(term)
    :ok = PaneHistoryWorker.stop(worker)
    assert_receive {:DOWN, ^ref, :process, ^term, _reason}, 2_000
  end

  test "reports pane_history_down when the emulator dies" do
    {:ok, _worker} =
      PaneHistoryWorker.start_link(
        parent: self(),
        pane_id: "%2",
        tmux_session: "devide_ws_s1",
        cols: 20,
        rows: 5,
        tmux_adapter: EmptyTmux
      )

    assert_receive {:pane_history_ready, "%2", term}

    Process.exit(term, :kill)
    assert_receive {:pane_history_down, "%2"}
  end
end
