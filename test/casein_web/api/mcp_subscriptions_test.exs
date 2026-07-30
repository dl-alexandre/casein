defmodule CaseinWeb.API.MCPSubscriptionsTest do
  @moduledoc """
  `subscriptions/listen` — the 2026-07-28 replacement for the GET SSE channel.

  The stream is the response to a POST, so these drive it through the real
  controller and read the accumulated chunked body.
  """

  use CaseinWeb.ConnCase, async: false

  alias Casein.Agents.MCPTasks
  alias CaseinWeb.API.MCPEnvelope

  @token "mcp-subscriptions-token"
  @path "/api/terminals/mcp"
  @tasks_ext %{"io.modelcontextprotocol/tasks" => %{}}

  setup do
    prev = Application.get_env(:casein, :api_token)
    Application.put_env(:casein, :api_token, @token)
    on_exit(fn -> restore(:api_token, prev) end)
    :ok
  end

  defp listen(task_ids, extensions \\ @tasks_ext) do
    %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "subscriptions/listen",
      "params" => %{
        "notifications" => %{"taskIds" => task_ids},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{"extensions" => extensions}
        }
      }
    }
  end

  defp post_mcp(conn, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post(@path, body)
  end

  defp sse_messages(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end

  test "an empty subscription is acknowledged and closed rather than held open", %{conn: conn} do
    response = post_mcp(conn, listen([]))

    assert response.status == 200
    assert get_resp_header(response, "content-type") |> hd() =~ "text/event-stream"
    # Reverse proxies must not buffer an SSE stream.
    assert get_resp_header(response, "x-accel-buffering") == ["no"]

    [ack, closure] = sse_messages(response.resp_body)

    # The acknowledgement MUST be the first message on the stream.
    assert ack["method"] == "notifications/subscriptions/acknowledged"
    assert ack["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == 7
    # We agreed to nothing, so the filter is empty rather than echoed back.
    assert ack["params"]["notifications"] == %{}

    # Graceful closure: the long-lived request gets its response, so the client
    # can tell a clean end from a dropped connection.
    assert closure["id"] == 7
    assert closure["result"]["resultType"] == "complete"
  end

  test "task ids the caller does not own are not acknowledged", %{conn: conn} do
    other_owner = %{
      server: "Casein Terminal MCP Server",
      workspace_id: "someone-else",
      actor: "global",
      capability_id: nil
    }

    {:ok, task_id} = MCPTasks.run(other_owner, fn _ -> {:ok, %{}} end)

    [ack | _] = sse_messages(post_mcp(conn, listen([task_id])).resp_body)

    # Silently narrowed, not an error — and the stream closes immediately since
    # there is nothing left to watch.
    assert ack["params"]["notifications"] == %{}
  end

  test "the stream forwards task notifications and closes on a terminal status", %{conn: conn} do
    owner = %{
      server: "Casein Terminal MCP Server",
      workspace_id: nil,
      actor: "global",
      capability_id: nil
    }

    {:ok, task_id} =
      MCPTasks.run(owner, fn _ ->
        receive do
          :never -> {:ok, %{}}
        end
      end)

    # The stream blocks, so it must run off the test process.
    streaming = Task.async(fn -> post_mcp(conn, listen([task_id])) end)

    # Re-announce until the stream has subscribed and consumed it. Racing the
    # subscription with a single broadcast would be flaky.
    response =
      await_stream(streaming, fn ->
        Phoenix.PubSub.broadcast(
          Casein.PubSub,
          MCPTasks.topic(task_id),
          {:mcp_task, %{taskId: task_id, status: "completed", result: %{"ok" => true}}}
        )
      end)

    messages = sse_messages(response.resp_body)
    assert [%{"method" => "notifications/subscriptions/acknowledged"} | rest] = messages

    notification = Enum.find(rest, &(&1["method"] == "notifications/tasks"))
    assert notification["params"]["taskId"] == task_id
    assert notification["params"]["status"] == "completed"
    assert notification["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == 7

    # Terminal status ends the stream.
    assert List.last(messages)["id"] == 7
  end

  test "subscriptions/listen is unavailable without the tasks extension", %{conn: conn} do
    response = post_mcp(conn, listen([], %{}))

    assert %{"error" => %{"code" => -32_601}} = json_response(response, 400)
  end

  test "subscriptions/listen is unavailable to legacy clients", %{conn: conn} do
    legacy = %{
      "jsonrpc" => "2.0",
      "id" => 8,
      "method" => "subscriptions/listen",
      "params" => %{"notifications" => %{}}
    }

    assert %{"error" => %{"code" => -32_601}} = json_response(post_mcp(conn, legacy), 400)
  end

  test "the envelope reports a stream outcome rather than a reply" do
    assert {:stream, subscription} =
             MCPEnvelope.handle(listen([]), CaseinWeb.API.TerminalMCP, [])

    assert subscription.id == 7
    assert subscription.task_ids == []
  end

  # Repeatedly runs `announce` until the streaming request returns.
  defp await_stream(task, announce, attempts \\ 200)

  defp await_stream(task, _announce, 0) do
    Task.shutdown(task, :brutal_kill)
    flunk("subscription stream never closed")
  end

  defp await_stream(task, announce, attempts) do
    announce.()

    case Task.yield(task, 25) do
      {:ok, response} -> response
      nil -> await_stream(task, announce, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
