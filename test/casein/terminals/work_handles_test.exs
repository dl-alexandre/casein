defmodule Casein.Terminals.WorkHandlesTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.AgentState
  alias Casein.Terminals.WorkHandles

  @ws "ws-work-handles-1"
  @session "casein_alpha_u-dev"

  setup do
    WorkHandles.clear_all()
    AgentState.clear()

    on_exit(fn ->
      WorkHandles.clear_all()
      AgentState.clear()
    end)

    :ok
  end

  test "create returns a durable id that get can resolve before any worker reports" do
    assert {:ok, handle} =
             WorkHandles.create(@ws,
               session: @session,
               pane_id: "%1",
               label: "s1-858",
               status: "working",
               message: "implement handles"
             )

    assert is_binary(handle.handle_id)
    assert handle.pane_id == "%1"
    assert handle.label == "s1-858"

    assert {:ok, resolved} = WorkHandles.get(handle.handle_id)
    assert resolved.handle_id == handle.handle_id
    assert resolved.pane == %{session: @session, pane_id: "%1"}
    # No AgentState report yet — falls back to the handle's recorded fields.
    assert resolved.status == %{
             source: "recorded",
             state: "working",
             message: "implement handles"
           }
  end

  test "respawn-then-resolve: reattach keeps the same handle_id on a new pane" do
    {:ok, handle} =
      WorkHandles.create(@ws,
        session: @session,
        pane_id: "%3",
        label: "lane-a",
        status: "working"
      )

    handle_id = handle.handle_id

    # Simulate respawn-pane -k: the old pane id dies, a new one appears.
    WorkHandles.prune_session(@session, [])
    _ = WorkHandles.get(handle_id)

    assert {:ok, unbound} = WorkHandles.get(handle_id)
    assert unbound.handle_id == handle_id
    assert unbound.pane == nil
    assert unbound.status.source == "recorded"

    assert {:ok, _reattached} = WorkHandles.attach(handle_id, @ws, @session, "%99")

    assert {:ok, resolved} = WorkHandles.get(handle_id)
    assert resolved.handle_id == handle_id
    assert resolved.pane == %{session: @session, pane_id: "%99"}
    assert resolved.pane_id == "%99"
    assert resolved.status.source == "recorded"
  end

  test "status prefers AgentState recorded report over handle fields, never pane title" do
    {:ok, handle} =
      WorkHandles.create(@ws, session: @session, pane_id: "%5", status: "working")

    :ok =
      AgentState.report(@ws, @session, "%5", :blocked, "need unlock",
        source: :mcp,
        tool: "test"
      )

    assert {:ok, resolved} = WorkHandles.get(handle.handle_id)

    assert resolved.status == %{
             source: "recorded",
             state: "blocked",
             message: "need unlock"
           }
  end

  test "list scopes to workspace and includes unbound handles after prune" do
    {:ok, a} = WorkHandles.create(@ws, session: @session, pane_id: "%1", label: "a")
    {:ok, _b} = WorkHandles.create("ws-other", session: @session, pane_id: "%2", label: "b")
    {:ok, c} = WorkHandles.create(@ws, label: "unattached")

    WorkHandles.prune_session(@session, [])
    _ = WorkHandles.get(a.handle_id)

    ids = WorkHandles.list(@ws) |> Enum.map(& &1.handle_id) |> Enum.sort()
    assert ids == Enum.sort([a.handle_id, c.handle_id])

    listed_a = Enum.find(WorkHandles.list(@ws), &(&1.handle_id == a.handle_id))
    assert listed_a.pane == nil
  end

  test "attach refuses a handle from another workspace" do
    {:ok, handle} = WorkHandles.create(@ws, session: @session, pane_id: "%1")

    assert {:error, :workspace_mismatch} =
             WorkHandles.attach(handle.handle_id, "ws-other", @session, "%2")
  end

  test "unknown handle is an error on get/attach" do
    assert WorkHandles.get("missing") == {:error, :unknown_handle}

    assert WorkHandles.attach("missing", @ws, @session, "%1") ==
             {:error, :unknown_handle}
  end

  test "record_status updates the handle without reading the screen" do
    {:ok, handle} = WorkHandles.create(@ws, status: "working")
    assert {:ok, _} = WorkHandles.record_status(handle.handle_id, :done, "landed")

    assert {:ok, resolved} = WorkHandles.get(handle.handle_id)
    assert resolved.status.state == "done"
    assert resolved.status.message == "landed"
    assert resolved.status.source == "recorded"
  end
end
