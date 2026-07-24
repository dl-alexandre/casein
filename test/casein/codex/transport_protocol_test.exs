defmodule Casein.Codex.TransportProtocolTest do
  use ExUnit.Case, async: true

  alias Casein.Codex.{ExecProtocol, HookProtocol}

  test "exec JSONL records normalize into lifecycle, item, and usage events" do
    assert {:ok, [thread]} =
             ExecProtocol.normalize(
               %{"type" => "thread.started", "thread_id" => "thr-exec"},
               context(:exec)
             )

    assert thread.type == :thread_started
    assert thread.transport == :exec

    assert {:ok, [completed, usage]} =
             ExecProtocol.normalize(
               %{
                 "type" => "turn.completed",
                 "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
               },
               Map.merge(context(:exec), %{thread_id: "thr-exec", turn_id: "turn-exec"})
             )

    assert completed.type == :turn_completed
    assert usage.type == :usage_updated
    assert usage.payload.total.total_tokens == 15
  end

  test "CLI hooks report blocked state and preserve subagent ancestry" do
    assert {:ok, [observed, blocked]} =
             HookProtocol.normalize(
               %{
                 "hook_event_name" => "PermissionRequest",
                 "session_id" => "root",
                 "turn_id" => "turn-1",
                 "reason" => "Needs network"
               },
               context(:hook)
             )

    assert observed.type == :hook_observed
    assert blocked.type == :thread_status_changed
    assert blocked.payload.active_flags == [:waiting_on_approval]

    assert {:ok, [child]} =
             HookProtocol.normalize(
               %{
                 "hook_event_name" => "SubagentStart",
                 "session_id" => "root",
                 "agent_id" => "child",
                 "agent_type" => "reviewer"
               },
               context(:hook)
             )

    assert child.type == :subagent_started
    assert child.thread_id == "child"
    assert child.parent_thread_id == "root"
  end

  defp context(transport) do
    %{
      workspace_id: "ws-transport",
      runtime_id: "runtime-transport",
      transport: transport,
      sequence: 1,
      occurred_at: ~U[2026-07-16 09:20:00Z]
    }
  end
end
