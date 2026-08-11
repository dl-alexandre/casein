defmodule Casein.Agents.WorkHandleToolsTest do
  use ExUnit.Case, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.WorkHandles

  @ws "ws-work-handle-tools"

  setup do
    WorkHandles.clear_all()
    AgentState.clear()

    on_exit(fn ->
      WorkHandles.clear_all()
      AgentState.clear()
    end)

    :ok
  end

  test "create / get / list over MCP without a live pane" do
    assert {:ok, created} =
             TerminalTools.invoke("terminal_work_handle_create", %{
               "workspace_id" => @ws,
               "label" => "s1-858",
               "status" => "working",
               "message" => "durable id"
             })

    assert is_binary(created.handle_id)
    assert created.status_action == "created"
    assert created.status.source == "recorded"
    assert created.status.state == "working"

    assert {:ok, got} =
             TerminalTools.invoke("terminal_work_handle_get", %{
               "workspace_id" => @ws,
               "handle_id" => created.handle_id
             })

    assert got.handle_id == created.handle_id

    assert {:ok, listed} =
             TerminalTools.invoke("terminal_work_handle_list", %{
               "workspace_id" => @ws
             })

    assert listed.count == 1
    assert Enum.any?(listed.handles, &(&1.handle_id == created.handle_id))
  end

  test "respawn-then-resolve: prune detaches, attach restores same handle_id" do
    {:ok, handle} =
      WorkHandles.create(@ws,
        session: "casein_alpha_u-dev",
        pane_id: "%3",
        label: "lane",
        status: "working"
      )

    handle_id = handle.handle_id

    # Pane dies (respawn-pane -k / wedge recovery).
    WorkHandles.prune_session("casein_alpha_u-dev", [])
    _ = WorkHandles.get(handle_id)

    assert {:ok, unbound} = WorkHandles.get(handle_id)
    assert unbound.pane == nil
    assert unbound.handle_id == handle_id

    assert {:ok, _} = WorkHandles.attach(handle_id, @ws, "casein_alpha_u-dev", "%42")

    assert {:ok, resolved} =
             TerminalTools.invoke("terminal_work_handle_get", %{
               "workspace_id" => @ws,
               "handle_id" => handle_id
             })

    assert resolved.handle_id == handle_id
    assert resolved.pane == %{session: "casein_alpha_u-dev", pane_id: "%42"}
    assert resolved.status.source == "recorded"
  end

  test "get refuses handles from another workspace" do
    {:ok, handle} = WorkHandles.create(@ws, label: "x")

    assert {:error, :unknown_handle} =
             TerminalTools.invoke("terminal_work_handle_get", %{
               "workspace_id" => "ws-other",
               "handle_id" => handle.handle_id
             })
  end
end
