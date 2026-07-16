defmodule DevIDE.AgentSessions.GrokACPTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.AgentSessions.GrokACP
  alias DevIDE.Agents.{Activity, AgentEvents}
  alias DevIDE.Test.GrokACPFakeTransport

  setup do
    Activity.clear()
    on_exit(fn -> Activity.clear() end)
    :ok
  end

  test "initializes, authenticates, loads a leader session, and surfaces structured events" do
    workspace_id = "grok-acp-ws-#{System.unique_integer([:positive])}"
    attachment_key = "grok-acp-test-#{System.unique_integer([:positive])}"
    Activity.subscribe(workspace_id)

    pid =
      start_supervised!(
        {GrokACP,
         {workspace_id, File.cwd!(),
          transport: GrokACPFakeTransport,
          test_pid: self(),
          attachment_key: attachment_key,
          session_id: "sess-shared"}}
      )

    assert_receive {:grok_acp_transport_started, ^pid}
    initialize = assert_request(pid, "initialize")
    assert initialize["params"]["protocolVersion"] == 1
    assert initialize["params"]["clientCapabilities"]["terminal"] == false

    send_json(pid, %{
      jsonrpc: "2.0",
      id: initialize["id"],
      result: %{
        protocolVersion: 1,
        agentCapabilities: %{loadSession: true},
        _meta: %{defaultAuthMethodId: "cached_token", "x.ai/pluginDirs": true}
      }
    })

    authenticate = assert_request(pid, "authenticate")
    assert authenticate["params"]["methodId"] == "cached_token"
    send_json(pid, %{jsonrpc: "2.0", id: authenticate["id"], result: %{}})

    load = assert_request(pid, "session/load")
    assert load["params"]["sessionId"] == "sess-shared"
    assert load["params"]["cwd"] == File.cwd!()
    assert load["params"]["mcpServers"] == []

    # Replay can arrive before session/load returns; the client must keep
    # reading and project it while the request is still pending.
    send_json(pid, %{
      jsonrpc: "2.0",
      method: "session/update",
      params: %{
        sessionId: "sess-shared",
        _meta: %{eventId: "grok-event-tool-1", sequence: 3},
        update: %{
          sessionUpdate: "tool_call",
          toolCallId: "tc-1",
          title: "Read file",
          kind: "read",
          status: "in_progress",
          rawInput: %{path: "private.ex"}
        }
      }
    })

    assert_receive {:agent_mcp_activity,
                    %{
                      source: :grok_acp,
                      tool: "grok_tool_call",
                      metadata: %{tool_call_id: "tc-1", status: "in_progress"}
                    }}

    assert [%{source_event_id: "grok-event-tool-1", event_type: "tool.started"}] =
             AgentEvents.list_for_session(workspace_id, "sess-shared")

    send_json(pid, %{jsonrpc: "2.0", id: load["id"], result: %{sessionId: "sess-shared"}})
    assert %{status: :ready, session_id: "sess-shared", protocol_version: 1} = GrokACP.status(pid)

    send_json(pid, %{
      jsonrpc: "2.0",
      method: "session/update",
      params: %{
        sessionId: "sess-shared",
        update: %{
          sessionUpdate: "plan",
          entries: [
            %{content: "sensitive plan text", status: "pending", priority: "high"},
            %{content: "more text", status: "completed", priority: "low"}
          ]
        }
      }
    })

    assert_receive {:agent_mcp_activity,
                    %{
                      source: :grok_acp,
                      tool: "grok_plan",
                      summary: "Plan updated · 2 steps",
                      metadata: %{step_count: 2}
                    }}

    permission_id = "permission-7"

    send_json(pid, %{
      jsonrpc: "2.0",
      id: permission_id,
      method: "session/request_permission",
      params: %{
        sessionId: "sess-shared",
        toolCall: %{toolCallId: "tc-2", title: "Execute tests", rawInput: "mix test"},
        options: [
          %{optionId: "allow-once", name: "Allow once", kind: "allow_once"},
          %{optionId: "reject-once", name: "Reject", kind: "reject_once"}
        ]
      }
    })

    assert_receive {:agent_mcp_activity,
                    %{
                      source: :grok_acp,
                      tool: "grok_permission_request",
                      metadata: %{status: "attention", option_count: 2}
                    }}

    assert [%{request_id: ^permission_id, tool_call_id: "tc-2"}] =
             GrokACP.status(pid).pending_permissions

    refute_receive {:grok_acp_transport_write, ^pid, _data}, 50
    assert :ok = GrokACP.respond_permission(pid, permission_id, "allow-once")

    assert_receive {:grok_acp_transport_write, ^pid, response_line}
    response = Jason.decode!(response_line)
    assert response["id"] == permission_id

    assert response["result"]["outcome"] == %{
             "outcome" => "selected",
             "optionId" => "allow-once"
           }

    assert GrokACP.status(pid).pending_permissions == []

    assert_receive {:agent_mcp_activity,
                    %{
                      source: :grok_acp,
                      tool: "grok_permission_decision",
                      metadata: %{outcome: "selected", option_id: "allow-once"}
                    }}

    assert Enum.any?(
             AgentEvents.list_for_session(workspace_id, "sess-shared"),
             &(&1.event_type == "permission.decided" and &1.status == "selected")
           )
  end

  test "creates a session when no shared session ID is supplied" do
    workspace_id = "grok-acp-new-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {GrokACP,
         {workspace_id, File.cwd!(),
          transport: GrokACPFakeTransport,
          test_pid: self(),
          attachment_key: workspace_id,
          auth_method_id: nil}}
      )

    assert_receive {:grok_acp_transport_started, ^pid}
    initialize = assert_request(pid, "initialize")

    send_json(pid, %{
      jsonrpc: "2.0",
      id: initialize["id"],
      result: %{protocolVersion: "1", agentCapabilities: %{loadSession: true}}
    })

    new_session = assert_request(pid, "session/new")
    send_json(pid, %{jsonrpc: "2.0", id: new_session["id"], result: %{sessionId: "sess-new"}})

    assert %{status: :ready, session_id: "sess-new"} = GrokACP.status(pid)
  end

  test "ensure_started reuses the collision-safe supervised attachment key" do
    workspace_id = "grok-acp-supervised-#{System.unique_integer([:positive])}"
    key = "observer"

    opts = [
      transport: GrokACPFakeTransport,
      test_pid: self(),
      attachment_key: key
    ]

    assert {:ok, first} = GrokACP.ensure_started(workspace_id, File.cwd!(), opts)
    assert_receive {:grok_acp_transport_started, ^first}
    assert {:ok, ^first} = GrokACP.ensure_started(workspace_id, File.cwd!(), opts)
    assert {:ok, ^first} = GrokACP.whereis(workspace_id, key)

    ref = Process.monitor(first)
    GrokACP.stop(first)
    assert_receive {:DOWN, ^ref, :process, ^first, :normal}
  end

  defp assert_request(pid, method) do
    assert_receive {:grok_acp_transport_write, ^pid, line}
    request = Jason.decode!(line)
    assert request["method"] == method
    request
  end

  defp send_json(pid, message) do
    line = Jason.encode!(message) <> "\n"
    split = max(div(byte_size(line), 2), 1)
    <<head::binary-size(^split), tail::binary>> = line
    send(pid, {:grok_acp_transport, :stdout, head})
    send(pid, {:grok_acp_transport, :stdout, tail})
  end
end
