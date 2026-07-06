defmodule DevIdeWeb.WorkspaceLive.PaneWorkerTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Test.FakeTerminalSession
  alias DevIDE.Test.FakeTerminals
  alias DevIdeWeb.WorkspaceLive.PaneWorker

  defp start_worker do
    start_supervised!(
      {PaneWorker,
       parent: self(),
       pane_id: "pane-gen-1",
       tmux_session: "devide_test_pane_worker_gen",
       backend: :shared_session,
       session_module: FakeTerminalSession,
       workspace_key: "ws-key-gen",
       session_sid: "sid-gen",
       loc: {:fake, self()},
       cols: 20,
       rows: 5}
    )
  end

  test "frames carry the session content generation when payloads have one" do
    worker = start_worker()

    send(worker, {:terminal_payload, :data, %{data: "hi", gen: 7}})

    assert_receive {:pane_frame, "pane-gen-1", %{content_gen: 7}}, 1_000
  end

  test "frames omit content_gen when the backend does not provide one" do
    worker = start_worker()

    send(worker, {:terminal_payload, :data, %{data: "hi"}})

    assert_receive {:pane_frame, "pane-gen-1", payload}, 1_000
    refute Map.has_key?(payload, :content_gen)
  end

  test "later payload generations replace earlier ones on subsequent frames" do
    worker = start_worker()

    send(worker, {:terminal_payload, :data, %{data: "a", gen: 1}})
    assert_receive {:pane_frame, "pane-gen-1", %{content_gen: 1}}, 1_000

    send(worker, {:terminal_payload, :data, %{data: "b", gen: 2}})
    assert_receive {:pane_frame, "pane-gen-1", %{content_gen: 2}}, 1_000
  end

  test "session_owner resize from a passive viewer does not reach the owner" do
    {:ok, worker} =
      PaneWorker.start_link(
        parent: self(),
        pane_id: "pane-passive-resize",
        tmux_session: "ignored",
        workspace_id: "ws-passive",
        workspace_key: "alpha",
        session_sid: "u-passive",
        loc: {:local, "/tmp"},
        backend: :session_owner,
        terminal_module: FakeTerminals,
        test_owner: self(),
        cols: 80,
        rows: 24
      )

    assert_receive {:fake_owner_attached, owner_pid, ^worker, _, _, _}, 1_000
    Process.unlink(worker)

    :ok = PaneWorker.set_active(worker, false)
    :ok = PaneWorker.resize(worker, 60, 20)
    refute_receive {:fake_owner_resize, ^owner_pid, _, _}, 100
    assert_receive {:pane_frame, "pane-passive-resize", _}, 1_000

    :ok = PaneWorker.set_active(worker, true)
    :ok = PaneWorker.resize(worker, 132, 44)
    assert_receive {:fake_owner_resize, ^owner_pid, 132, 44}, 1_000

    ref = Process.monitor(worker)
    assert :ok = GenServer.stop(worker, :normal)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
  end

  test "terminal_owner_size resizes the local grid without owner_resize" do
    {:ok, worker} =
      PaneWorker.start_link(
        parent: self(),
        pane_id: "pane-owner-size",
        tmux_session: "ignored",
        workspace_id: "ws-owner-size",
        workspace_key: "alpha",
        session_sid: "u-owner-size",
        loc: {:local, "/tmp"},
        backend: :session_owner,
        terminal_module: FakeTerminals,
        test_owner: self(),
        cols: 80,
        rows: 24
      )

    assert_receive {:fake_owner_attached, owner_pid, ^worker, _, _, _}, 1_000
    Process.unlink(worker)

    send(worker, {:terminal_owner_size, 200, 60})
    refute_receive {:fake_owner_resize, ^owner_pid, _, _}, 100
    assert_receive {:pane_frame, "pane-owner-size", _}, 1_000

    ref = Process.monitor(worker)
    assert :ok = GenServer.stop(worker, :normal)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
  end
end
