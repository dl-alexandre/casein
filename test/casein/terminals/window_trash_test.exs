defmodule Casein.Terminals.WindowTrashTest do
  @moduledoc """
  Deferred, undoable window close.

  The contract under test is that closing a window is *not* a kill until the
  grace period runs out — that gap is the whole feature, so most of these tests
  are about what has NOT happened yet.
  """

  use Casein.TestCase, async: false

  alias Casein.Terminals.WindowTrash
  alias TmuxCtl.Test.FakeState

  setup do
    prev_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_grace = Application.get_env(:casein, :window_trash_grace_ms)
    prev_test_pid = FakeState.get(:fake_tmux_test_pid)

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    # Long enough that nothing expires mid-test unless a test asks for it.
    Application.put_env(:casein, :window_trash_grace_ms, 60_000)
    # The deferred kill runs in the WindowTrash process, not the test's, so the
    # fake adapter needs an explicit pid to report to — without this every
    # refute_receive below would pass vacuously.
    FakeState.put(:fake_tmux_test_pid, self())
    WindowTrash.__reset__()

    on_exit(fn ->
      WindowTrash.__reset__()
      restore(:tmux_adapter, prev_adapter)
      restore(:window_trash_grace_ms, prev_grace)

      if prev_test_pid,
        do: FakeState.put(:fake_tmux_test_pid, prev_test_pid),
        else: FakeState.delete(:fake_tmux_test_pid)
    end)

    %{session: "casein_wt-#{System.unique_integer([:positive])}_u-alice"}
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp windows(ids), do: Enum.map(ids, &%{id: &1, name: "w#{&1}"})

  describe "trash/3" do
    test "hides the window from viewers without touching tmux", %{session: session} do
      assert {:ok, grace} = WindowTrash.trash(session, "@1", "build")
      assert grace == 60_000

      # The point of the grace period: nothing has been killed yet.
      refute_receive {:fake_tmux_kill_window, ^session, "@1"}

      assert WindowTrash.pending?(session, "@1")
      assert WindowTrash.pending_ids(session) == MapSet.new(["@1"])

      assert WindowTrash.reject_pending(session, windows(["@0", "@1", "@2"])) ==
               windows(["@0", "@2"])
    end

    test "leaves other sessions alone", %{session: session} do
      other = session <> "-other"
      {:ok, _} = WindowTrash.trash(session, "@1", "build")

      assert WindowTrash.pending_ids(other) == MapSet.new()
      assert WindowTrash.reject_pending(other, windows(["@1"])) == windows(["@1"])
    end

    test "broadcasts so every viewer on the session re-filters", %{session: session} do
      :ok = WindowTrash.subscribe(session)
      {:ok, _} = WindowTrash.trash(session, "@1", "build")

      assert_receive {:window_trash_changed, ^session}
    end

    test "a second close of the same window does not restart the clock", %{session: session} do
      {:ok, _} = WindowTrash.trash(session, "@1", "build")
      {:ok, _} = WindowTrash.trash(session, "@1", "build")

      # Still exactly one pending entry, and still nothing killed.
      assert WindowTrash.pending_ids(session) == MapSet.new(["@1"])
      assert {:ok, "build"} = WindowTrash.restore(session, "@1")
      assert {:error, :not_pending} = WindowTrash.restore(session, "@1")
    end
  end

  describe "restore/2" do
    test "unhides the window and cancels the kill", %{session: session} do
      Application.put_env(:casein, :window_trash_grace_ms, 80)
      {:ok, _} = WindowTrash.trash(session, "@1", "build")

      assert {:ok, "build"} = WindowTrash.restore(session, "@1")
      refute WindowTrash.pending?(session, "@1")
      assert WindowTrash.reject_pending(session, windows(["@1"])) == windows(["@1"])

      # The timer was cancelled, not merely ignored — waiting past the original
      # deadline must not produce a late kill.
      refute_receive {:fake_tmux_kill_window, ^session, "@1"}, 300
    end

    test "broadcasts the restore", %{session: session} do
      {:ok, _} = WindowTrash.trash(session, "@1", "build")
      :ok = WindowTrash.subscribe(session)

      {:ok, _} = WindowTrash.restore(session, "@1")
      assert_receive {:window_trash_changed, ^session}
    end

    test "refuses a window that was never closed", %{session: session} do
      assert {:error, :not_pending} = WindowTrash.restore(session, "@9")
    end
  end

  describe "restore_latest/1" do
    test "restores the most recent close, not the first", %{session: session} do
      {:ok, _} = WindowTrash.trash(session, "@1", "first")
      # Distinct monotonic timestamps; the ordering is what is under test.
      Process.sleep(5)
      {:ok, _} = WindowTrash.trash(session, "@2", "second")

      assert {:ok, "@2", "second"} = WindowTrash.restore_latest(session)
      assert WindowTrash.pending_ids(session) == MapSet.new(["@1"])

      assert {:ok, "@1", "first"} = WindowTrash.restore_latest(session)
      assert {:error, :nothing_pending} = WindowTrash.restore_latest(session)
    end

    test "reports when there is nothing to undo", %{session: session} do
      assert {:error, :nothing_pending} = WindowTrash.restore_latest(session)
    end
  end

  describe "expiry" do
    test "kills the window for real once the grace period runs out", %{session: session} do
      Application.put_env(:casein, :window_trash_grace_ms, 50)
      {:ok, 50} = WindowTrash.trash(session, "@1", "build")

      assert_receive {:fake_tmux_kill_window, ^session, "@1"}, 1_000

      # Once it is really gone it stops being hidden-pending and stops being
      # restorable — the undo affordance must not lie about what it can do.
      refute WindowTrash.pending?(session, "@1")
      assert {:error, :not_pending} = WindowTrash.restore(session, "@1")
    end

    test "broadcasts on expiry so viewers converge", %{session: session} do
      :ok = WindowTrash.subscribe(session)
      Application.put_env(:casein, :window_trash_grace_ms, 50)
      {:ok, _} = WindowTrash.trash(session, "@1", "build")

      assert_receive {:window_trash_changed, ^session}
      assert_receive {:window_trash_changed, ^session}, 1_000
    end
  end

  describe "grace_ms/0" do
    test "falls back to the default for nonsense configuration" do
      Application.put_env(:casein, :window_trash_grace_ms, 0)
      assert WindowTrash.grace_ms() == 30_000

      Application.put_env(:casein, :window_trash_grace_ms, "soon")
      assert WindowTrash.grace_ms() == 30_000
    end
  end

  describe "reject_pending/2" do
    test "passes lists through untouched when nothing is pending", %{session: session} do
      list = windows(["@0", "@1"])
      assert WindowTrash.reject_pending(session, list) == list
      assert WindowTrash.reject_pending(nil, list) == list
    end
  end
end
