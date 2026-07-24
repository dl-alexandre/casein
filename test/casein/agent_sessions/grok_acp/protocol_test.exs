defmodule Casein.AgentSessions.GrokACP.ProtocolTest do
  use Casein.TestCase, async: true

  alias Casein.AgentSessions.GrokACP.Protocol

  test "decodes partial and multiple JSONL messages without merging stderr" do
    first = Jason.encode!(%{jsonrpc: "2.0", id: 1, result: %{protocolVersion: 1}})
    second = Jason.encode!(%{jsonrpc: "2.0", method: "session/update", params: %{}})
    split = div(byte_size(first), 2)
    <<head::binary-size(^split), tail::binary>> = first

    assert {[], ^head} = Protocol.feed("", head)

    assert {messages, "remaining"} =
             Protocol.feed(head, tail <> "\n" <> second <> "\nremaining")

    assert [
             {:ok, %{"id" => 1, "result" => %{"protocolVersion" => 1}}},
             {:ok, %{"method" => "session/update"}}
           ] = messages
  end

  test "classifies the three observed ACP event families" do
    assert {:activity, {:tool_call, %{"title" => "Read"}}, identity} =
             Protocol.classify(%{
               "method" => "session/update",
               "params" => %{
                 "sessionId" => "sess-1",
                 "_meta" => %{"eventId" => "event-tool-1", "sequence" => 17},
                 "update" => %{"sessionUpdate" => "tool_call", "title" => "Read"}
               }
             })

    assert identity == %{
             session_id: "sess-1",
             source_event_id: "event-tool-1",
             source_sequence: 17
           }

    assert {:activity, {:plan, %{"entries" => []}}, plan_identity} =
             Protocol.classify(%{
               "method" => "session/update",
               "params" => %{
                 "sessionId" => "sess-1",
                 "update" => %{"sessionUpdate" => "plan", "entries" => []}
               }
             })

    assert plan_identity.session_id == "sess-1"
    assert String.starts_with?(plan_identity.source_event_id, "derived:")

    assert {:permission_request, 42, %{"sessionId" => "sess-1"}} =
             Protocol.classify(%{
               "id" => 42,
               "method" => "session/request_permission",
               "params" => %{"sessionId" => "sess-1"}
             })
  end

  test "normalizes metadata without raw tool input, output, or plan content" do
    tool_attrs =
      Protocol.activity_attrs(
        "ws-1",
        {:tool_call,
         %{
           "toolCallId" => "tc-1",
           "title" => "Read file",
           "kind" => "read",
           "status" => "in_progress",
           "rawInput" => %{"path" => "secret.ex"},
           "content" => [%{"text" => "source code"}]
         }},
        "sess-1"
      )

    assert tool_attrs.source == :grok_acp
    assert tool_attrs.tool == "grok_tool_call"
    assert tool_attrs.metadata.tool_call_id == "tc-1"
    refute Map.has_key?(tool_attrs.metadata, :raw_input)
    refute inspect(tool_attrs) =~ "source code"
    refute inspect(tool_attrs) =~ "secret.ex"

    plan_attrs =
      Protocol.activity_attrs(
        "ws-1",
        {:plan,
         %{
           "entries" => [
             %{"content" => "private implementation details", "status" => "pending"}
           ]
         }},
        "sess-1"
      )

    assert plan_attrs.summary == "Plan updated · 1 step"
    assert plan_attrs.metadata.status_counts == %{"pending" => 1}
    refute inspect(plan_attrs) =~ "private implementation details"
  end
end
