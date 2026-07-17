defmodule DevIDE.Codex.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DevIDE.Codex.{Approval, Event, Runtime}

  @fixture Path.expand("../../fixtures/codex_app_server/fake_app_server.sh", __DIR__)

  test "routes an approval atomically and resumes a thread after App Server restart" do
    runtime_id = "runtime-spine-#{System.unique_integer([:positive])}"

    start_runtime!(runtime_id)
    assert_receive {:codex_app_server_status, ^runtime_id, :initializing, _metadata}
    assert :ok = Runtime.await_ready(runtime_id)
    assert_receive {:codex_app_server_status, ^runtime_id, :ready, _metadata}

    assert {:ok, %{thread_id: "thr_fake"}} = Runtime.start_thread(runtime_id)
    assert_receive {:codex_event, %Event{type: :thread_started, sequence: 1}}

    assert {:ok, %{turn_id: "turn_fake"}} =
             Runtime.start_turn(runtime_id, "thr_fake", "Request an approval")

    assert_receive {:codex_event, %Event{type: :turn_started, sequence: 2}}
    assert_receive {:codex_event, %Event{type: :agent_message_delta, sequence: 3}}

    assert_receive {:codex_event, %Event{type: :approval_requested, sequence: 4} = requested}

    assert requested.payload.approval_kind == :command_execution
    assert requested.payload.command == "git status"
    approval_id = requested.payload.approval_id

    assert [%Approval{id: ^approval_id, status: :pending}] =
             Runtime.pending_approvals(runtime_id)

    assert {:error, :invalid_decision} =
             Runtime.resolve_approval(runtime_id, approval_id, :unexpected)

    assert {:ok, %Approval{status: :granted, resolution: :accept}} =
             Runtime.resolve_approval(runtime_id, approval_id, :accept)

    assert_receive {:codex_event, %Event{type: :approval_resolved, sequence: 5} = resolved}
    assert resolved.payload.status == :granted
    assert_receive {:codex_event, %Event{type: :turn_completed, sequence: 6}}
    assert [] = Runtime.pending_approvals(runtime_id)

    assert {:error, :already_resolved} =
             Runtime.resolve_approval(runtime_id, approval_id, :accept)

    old_app_server = Runtime.whereis_component(runtime_id, :app_server)
    ref = Process.monitor(old_app_server)

    capture_log(fn ->
      :ok = GenServer.stop(old_app_server, :test_restart)
      assert_receive {:DOWN, ^ref, :process, ^old_app_server, :test_restart}
      assert_receive {:codex_app_server_status, ^runtime_id, :stopped, _metadata}
      assert_receive {:codex_app_server_status, ^runtime_id, :initializing, _metadata}
      assert_receive {:codex_app_server_status, ^runtime_id, :ready, _metadata}
    end)

    new_app_server = Runtime.whereis_component(runtime_id, :app_server)
    assert is_pid(new_app_server)
    refute new_app_server == old_app_server

    assert {:ok,
            %{
              thread_id: "thr_fake",
              cwd: "/workspace",
              model: "gpt-5",
              model_provider: "openai"
            }} = Runtime.resume_thread(runtime_id, "thr_fake")

    assert_receive {:codex_event, %Event{type: :thread_status_changed, sequence: 7}}
    assert %{sequence: 7, runtime_status: :ready} = Runtime.snapshot(runtime_id)
  end

  defp start_runtime!(runtime_id) do
    pid =
      start_supervised!(
        {DevIDE.Codex.Runtime,
         workspace_id: "ws-spine",
         runtime_id: runtime_id,
         cwd: File.cwd!(),
         executable: "/bin/sh",
         args: [@fixture],
         subscriber: self()}
      )

    pid
  end
end
