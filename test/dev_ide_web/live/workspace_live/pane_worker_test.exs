defmodule DevIdeWeb.WorkspaceLive.PaneWorkerTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Test.FakeTerminalSession
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
end
