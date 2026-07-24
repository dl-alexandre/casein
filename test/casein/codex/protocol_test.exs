defmodule Casein.Codex.ProtocolTest do
  use ExUnit.Case, async: true

  alias Casein.Codex.{Event, JsonRpc, Protocol}

  @fixture Path.expand("../../fixtures/codex_app_server/notifications.jsonl", __DIR__)

  test "normalizes the supported notification spine into one canonical contract" do
    events =
      @fixture
      |> File.stream!(:line, [])
      |> Stream.map(&String.trim/1)
      |> Stream.with_index(1)
      |> Enum.map(fn {line, sequence} ->
        assert {:ok, decoded} = JsonRpc.decode(line)
        assert {:ok, %Event{} = event} = Protocol.normalize(decoded, context(sequence))
        event
      end)

    assert Enum.map(events, & &1.type) == [
             :thread_started,
             :thread_status_changed,
             :turn_started,
             :agent_message_delta,
             :turn_completed
           ]

    assert Enum.map(events, & &1.sequence) == [1, 2, 3, 4, 5]
    assert Enum.all?(events, &(&1.workspace_id == "ws-1"))
    assert Enum.all?(events, &(&1.runtime_id == "runtime-1"))
    assert Enum.all?(events, &(&1.transport == :app_server))

    [thread, status, started, delta, completed] = events

    assert thread.thread_id == "thr_root"
    assert thread.session_id == "sess_1"
    assert thread.payload.status == :idle
    assert thread.payload.source == :app_server
    assert thread.payload.created_at == ~U[2026-07-15 22:40:00Z]

    assert status.payload == %{status: :active, active_flags: [:waiting_on_approval]}
    assert started.turn_id == "turn_1"
    assert started.payload.status == :in_progress
    assert delta.item_id == "item_1"
    assert delta.payload.delta == "Hello from Codex"
    assert completed.payload.status == :completed
    assert completed.payload.duration_ms == 2_000
  end

  test "ignores unknown notifications and rejects broken supported ones" do
    assert :ignore =
             Protocol.normalize({:notification, "account/updated", %{}}, context(1))

    assert {:error, {:missing_field, "params.turnId"}} =
             Protocol.normalize(
               {:notification, "item/agentMessage/delta",
                %{"threadId" => "thr", "itemId" => "item", "delta" => "hello"}},
               context(2)
             )
  end

  test "normalizes initialize, thread-start, and turn-start responses" do
    assert {:ok, %{user_agent: "codex/1", platform_family: "unix", platform_os: "linux"}} =
             Protocol.normalize_response(:initialize, %{
               "userAgent" => "codex/1",
               "platformFamily" => "unix",
               "platformOs" => "linux"
             })

    assert {:ok, %{thread_id: "thr", session_id: "sess", thread: %{status: :idle}}} =
             Protocol.normalize_response(:thread_start, %{
               "thread" => %{
                 "id" => "thr",
                 "sessionId" => "sess",
                 "status" => %{"type" => "idle"}
               }
             })

    assert {:ok, %{turn_id: "turn", turn: %{status: :in_progress}}} =
             Protocol.normalize_response(:turn_start, %{
               "turn" => %{"id" => "turn", "status" => "inProgress"}
             })

    assert {:ok,
            %{
              thread_id: "thr",
              cwd: "/workspace",
              model: "gpt-5",
              model_provider: "openai"
            }} =
             Protocol.normalize_response(:thread_resume, %{
               "cwd" => "/workspace",
               "model" => "gpt-5",
               "modelProvider" => "openai",
               "thread" => %{"id" => "thr", "status" => %{"type" => "idle"}}
             })
  end

  test "normalizes command approval requests without leaking the wire shape" do
    request =
      {:request, "approval-1", "item/commandExecution/requestApproval",
       %{
         "threadId" => "thr",
         "turnId" => "turn",
         "itemId" => "item",
         "command" => "git status",
         "cwd" => "/workspace",
         "reason" => "Inspect the worktree",
         "startedAtMs" => 1_784_155_201_500
       }}

    assert {:ok, approval} = Protocol.normalize_server_request(request, context(1))
    assert approval.kind == :command_execution
    assert approval.request_id == "approval-1"
    assert approval.thread_id == "thr"
    assert approval.turn_id == "turn"
    assert approval.item_id == "item"
    assert approval.requested_at == ~U[2026-07-15 22:40:01.500Z]
    assert approval.payload.command == "git status"
    assert approval.payload.cwd == "/workspace"
    assert approval.metadata == %{codex_method: "item/commandExecution/requestApproval"}
  end

  defp context(sequence) do
    %{
      workspace_id: "ws-1",
      runtime_id: "runtime-1",
      transport: :app_server,
      sequence: sequence,
      occurred_at: ~U[2026-07-15 22:00:00Z]
    }
  end
end
