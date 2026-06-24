defmodule DevIDE.Agents.MCPSessionsTest do
  @moduledoc """
  The Streamable HTTP session registry: create/fetch/delete, attaching an SSE
  consumer, pushing notifications to it, and auto-detaching when the consumer
  process dies.
  """
  use ExUnit.Case, async: false

  alias DevIDE.Agents.MCPSessions

  test "create issues a fetchable session id with metadata" do
    id = MCPSessions.create(%{server: :terminal, workspace_id: "ws-1"})

    assert is_binary(id) and byte_size(id) > 0
    assert {:ok, meta} = MCPSessions.fetch(id)
    assert meta.server == :terminal
    assert meta.workspace_id == "ws-1"
    assert is_integer(meta.created_at)
    assert MCPSessions.exists?(id)
  end

  test "unknown session ids are not found" do
    refute MCPSessions.exists?("nope")
    assert :error = MCPSessions.fetch("nope")
    refute MCPSessions.exists?(nil)
  end

  test "delete removes the session" do
    id = MCPSessions.create(%{server: :preview})
    assert :ok = MCPSessions.delete(id)
    refute MCPSessions.exists?(id)
  end

  test "notify pushes a message to the attached consumer" do
    id = MCPSessions.create(%{server: :terminal})
    test_pid = self()

    consumer =
      spawn(fn ->
        :ok = MCPSessions.attach_stream(id, self())
        send(test_pid, :attached)

        receive do
          {:mcp_sse, message} -> send(test_pid, {:got, message})
        after
          1000 -> send(test_pid, :timeout)
        end
      end)

    assert_receive :attached, 1000
    assert MCPSessions.streaming?(id)

    assert :ok = MCPSessions.notify(id, %{jsonrpc: "2.0", method: "notifications/progress"})
    assert_receive {:got, %{method: "notifications/progress"}}, 1000

    # Consumer has exited after receiving; the registry detaches it.
    refute Process.alive?(consumer)
    wait_until(fn -> not MCPSessions.streaming?(id) end)
    assert {:error, :no_stream} = MCPSessions.notify(id, %{jsonrpc: "2.0"})
  end

  test "attach_stream rejects unknown sessions" do
    assert {:error, :unknown_session} = MCPSessions.attach_stream("ghost", self())
  end

  test "a dead consumer is auto-detached" do
    id = MCPSessions.create(%{server: :preview})

    consumer =
      spawn(fn ->
        :ok = MCPSessions.attach_stream(id, self())
        Process.sleep(:infinity)
      end)

    wait_until(fn -> MCPSessions.streaming?(id) end)
    Process.exit(consumer, :kill)
    wait_until(fn -> not MCPSessions.streaming?(id) end)

    assert {:error, :no_stream} = MCPSessions.notify(id, %{jsonrpc: "2.0"})
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
