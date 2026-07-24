defmodule Casein.Codex.AppServerTest do
  use ExUnit.Case, async: false

  alias Casein.Codex.{AppServer, Event}

  @fixture Path.expand("../../fixtures/codex_app_server/fake_app_server.sh", __DIR__)

  test "owns the JSONL port and emits only normalized lifecycle events" do
    pid =
      start_supervised!(
        {AppServer,
         workspace_id: "ws-fake",
         runtime_id: "runtime-fake",
         cwd: File.cwd!(),
         executable: "/bin/sh",
         args: [@fixture],
         subscriber: self()}
      )

    assert_receive {:codex_app_server_status, "runtime-fake", :initializing, _metadata}
    assert :ok = AppServer.await_ready(pid)

    assert_receive {:codex_app_server_status, "runtime-fake", :ready,
                    %{metadata: %{user_agent: "fake-codex/1.0"}}}

    assert %{
             status: :ready,
             sequence: 0,
             security: %{
               "approvalPolicy" => "on-request",
               "sandbox" => "workspace-write"
             }
           } = AppServer.status(pid)

    assert {:ok, %{thread_id: "thr_fake", session_id: "sess_fake"}} =
             AppServer.start_thread(pid, %{
               "config" => %{
                 "shell_environment_policy" => %{
                   "ignore_default_excludes" => true,
                   "set" => %{"DEV_IDE_API_TOKEN" => "must-not-reach-shells"}
                 }
               }
             })

    assert_receive {:codex_event, %Event{type: :thread_started, sequence: 1} = thread}
    assert thread.thread_id == "thr_fake"
    assert thread.payload.status == :idle

    assert {:ok, %{turn_id: "turn_fake"}} =
             AppServer.start_turn(pid, "thr_fake", "Say hello")

    assert_receive {:codex_event, %Event{type: :turn_started, sequence: 2}}

    assert_receive {:codex_event, %Event{type: :agent_message_delta, sequence: 3} = delta}

    assert delta.payload == %{delta: "fake response"}

    assert_receive {:codex_event, %Event{type: :turn_completed, sequence: 4} = completed}
    assert completed.payload.status == :completed
    assert AppServer.status(pid).sequence == 4
  end

  test "rejects invalid turn input before touching the transport" do
    pid = start_fake_server("runtime-invalid-input")
    assert :ok = AppServer.await_ready(pid)
    assert {:error, :invalid_turn_input} = AppServer.start_turn(pid, "thr", "")
  end

  test "maps guarded workspace modes to read-only Codex defaults" do
    pid =
      start_supervised!(
        {AppServer,
         workspace_id: "ws-review",
         runtime_id: "runtime-review",
         workspace_mode: :review,
         cwd: File.cwd!(),
         executable: "/bin/sh",
         args: [@fixture]}
      )

    assert :ok = AppServer.await_ready(pid)

    assert AppServer.status(pid).security == %{
             "approvalPolicy" => "never",
             "sandbox" => "read-only"
           }
  end

  defp start_fake_server(runtime_id) do
    start_supervised!(
      {AppServer,
       workspace_id: "ws-fake",
       runtime_id: runtime_id,
       cwd: File.cwd!(),
       executable: "/bin/sh",
       args: [@fixture]}
    )
  end
end
