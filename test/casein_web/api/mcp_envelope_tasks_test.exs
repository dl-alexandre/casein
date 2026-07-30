defmodule CaseinWeb.API.MCPEnvelopeTasksTest do
  @moduledoc """
  Task augmentation in the shared MCP envelope.

  Uses a stub handler so the test controls when background work reports, and so
  the wiring is exercised without a live tmux/preview surface.
  """

  use ExUnit.Case, async: false

  alias Casein.Agents.MCPTasks
  alias Casein.Test.Eventually
  alias CaseinWeb.API.MCPEnvelope

  @tasks_ext %{"io.modelcontextprotocol/tasks" => %{}}

  defmodule StubHandler do
    @moduledoc false
    @behaviour CaseinWeb.API.MCPEnvelope

    alias CaseinWeb.API.MCPEnvelope

    @impl true
    def server_name, do: "Stub MCP Server"

    @impl true
    def instructions(_opts), do: "stub instructions"

    @impl true
    def list_tools(_opts) do
      [%{name: "zeta_tool"}, %{name: "alpha_tool"}, %{name: "slow_tool"}]
    end

    @impl true
    def task_tools, do: ["slow_tool", "plain_tool"]

    @impl true
    def list_resources(_opts), do: []

    @impl true
    def read_resource(_uri, _opts), do: {:error, :not_found}

    @impl true
    # Blocks until the test releases it, and reports back what the envelope told
    # it about the task context.
    def call_tool(id, %{"name" => "slow_tool"}, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:tool_running, self(), Keyword.get(opts, :task_augmented, false),
         Keyword.get(opts, :task_id)}
      )

      receive do
        :finish -> MCPEnvelope.result(id, %{content: [], structuredContent: %{"slow" => true}})
      end
    end

    def call_tool(id, %{"name" => name}, _opts) do
      MCPEnvelope.result(id, %{content: [], structuredContent: %{"sync" => name}})
    end
  end

  defp opts(extra \\ []), do: Keyword.merge([test_pid: self(), actor: "global"], extra)

  defp modern(method, params, extensions) do
    %{
      "jsonrpc" => "2.0",
      "id" => "task-rpc-1",
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{"extensions" => extensions}
        })
    }
  end

  defp call(message, opts), do: MCPEnvelope.handle(message, StubHandler, opts)

  test "a Tasks client gets a handle instead of a blocked connection" do
    message = modern("tools/call", %{"name" => "slow_tool"}, @tasks_ext)

    assert {:reply, %{result: result}} = call(message, opts())

    # `resultType` is "task", not the "complete" every other result gets.
    assert result.resultType == "task"
    assert is_binary(result.taskId)
    assert result.status == "working"
    assert result.pollIntervalMs > 0

    assert_receive {:tool_running, worker, true, task_id}
    assert task_id == result.taskId

    send(worker, :finish)

    task =
      Eventually.await(
        fn ->
          case MCPTasks.get(result.taskId, owner()) do
            {:ok, %{status: "completed"} = task} -> task
            _ -> nil
          end
        end,
        message: "task never completed"
      )

    assert task.result.structuredContent == %{"slow" => true}
  end

  test "the same tool stays synchronous for a client that did not declare Tasks" do
    # Modern revision, but no Tasks extension — must not receive a task.
    assert {:reply, %{result: result}} =
             call(modern("tools/call", %{"name" => "plain_tool"}, %{}), opts())

    assert result.resultType == "complete"
    assert result.structuredContent == %{"sync" => "plain_tool"}
    refute Map.has_key?(result, :taskId)
  end

  test "a legacy client never receives a task" do
    legacy = %{
      "jsonrpc" => "2.0",
      "id" => "legacy-1",
      "method" => "tools/call",
      "params" => %{"name" => "plain_tool"}
    }

    assert {:reply, %{result: result}} = call(legacy, opts())
    refute Map.has_key?(result, :taskId)
    refute Map.has_key?(result, :resultType)
  end

  test "a tool the handler did not nominate is never task-augmented" do
    assert {:reply, %{result: result}} =
             call(modern("tools/call", %{"name" => "alpha_tool"}, @tasks_ext), opts())

    assert result.resultType == "complete"
    refute Map.has_key?(result, :taskId)
  end

  test "tasks/get reports progress and then the final result" do
    assert {:reply, %{result: %{taskId: task_id}}} =
             call(modern("tools/call", %{"name" => "slow_tool"}, @tasks_ext), opts())

    assert_receive {:tool_running, worker, true, ^task_id}

    assert {:reply, %{result: working}} =
             call(modern("tasks/get", %{"taskId" => task_id}, @tasks_ext), opts())

    assert working.status == "working"
    # A tasks/get response is an ordinary complete result.
    assert working.resultType == "complete"
    refute Map.has_key?(working, :result)

    send(worker, :finish)

    Eventually.await(fn ->
      {:reply, %{result: task}} =
        call(modern("tasks/get", %{"taskId" => task_id}, @tasks_ext), opts())

      task.status == "completed" and task.result.structuredContent == %{"slow" => true}
    end)
  end

  test "tasks/cancel is terminal and stops the worker" do
    assert {:reply, %{result: %{taskId: task_id}}} =
             call(modern("tools/call", %{"name" => "slow_tool"}, @tasks_ext), opts())

    assert_receive {:tool_running, worker, true, ^task_id}

    assert {:reply, %{result: %{}}} =
             call(modern("tasks/cancel", %{"taskId" => task_id}, @tasks_ext), opts())

    assert {:reply, %{result: %{status: "cancelled"}}} =
             call(modern("tasks/get", %{"taskId" => task_id}, @tasks_ext), opts())

    Eventually.await(fn -> not Process.alive?(worker) end, message: "worker was not stopped")
  end

  test "another workspace cannot read the task" do
    assert {:reply, %{result: %{taskId: task_id}}} =
             call(
               modern("tools/call", %{"name" => "slow_tool"}, @tasks_ext),
               opts(default_workspace_id: "ws-a")
             )

    assert_receive {:tool_running, worker, true, ^task_id}

    assert {:error, %{error: %{code: -32_602, data: %{code: "unknown_task"}}}} =
             call(
               modern("tasks/get", %{"taskId" => task_id}, @tasks_ext),
               opts(default_workspace_id: "ws-b")
             )
             |> unwrap_reply()

    send(worker, :finish)
  end

  test "tasks/* are unavailable to clients that did not declare the extension" do
    for method <- ["tasks/get", "tasks/update", "tasks/cancel"] do
      assert {:error, %{error: %{code: -32_601}}} =
               call(modern(method, %{"taskId" => "whatever"}, %{}), opts())
    end
  end

  test "tasks/get requires a taskId" do
    assert {:reply, %{error: %{code: -32_602, message: message}}} =
             call(modern("tasks/get", %{}, @tasks_ext), opts())

    assert message =~ "taskId"
  end

  test "server/discover advertises the tasks extension" do
    assert {:reply, %{result: result}} = call(modern("server/discover", %{}, @tasks_ext), opts())
    assert Map.has_key?(result.capabilities.extensions, "io.modelcontextprotocol/tasks")
  end

  defp owner do
    %{server: "Stub MCP Server", workspace_id: nil, actor: "global", capability_id: nil}
  end

  # `tasks/get` on an unknown task replies with a JSON-RPC error inside a
  # `{:reply, _}` (not `{:error, _}`), since the request itself was well-formed.
  defp unwrap_reply({:reply, response}), do: {:error, response}
  defp unwrap_reply(other), do: other
end
