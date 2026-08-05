defmodule Casein.Panes.EventsBroadcastIsolationTest do
  @moduledoc """
  Regression guard for #314 on the *transitive* broadcast path.

  `Casein.Panes.Events.broadcast/1` is only ever reached from inside a singleton
  GenServer callback (`Casein.PreviewPanes` via `broadcast_pane_event/3`,
  `Casein.FilePanes` via `Casein.FilePanes.Payload.broadcast/2`). If it resolves
  workspace aliases with `resolve_remote?: true`, a cold-`State` workspace falls
  through to a synchronous Manager HTTP call with a 15s receive timeout — inside
  the named process — and every pane operation on the box queues behind it.

  The direct `viewer_ids/2` calls in `preview_panes.ex` were hardened when #314
  was fixed; this shared helper was missed. These tests fail if it regresses
  again.

  The second test pins the deliberate *asymmetry*: `subscribe/1` is caller-side
  (it runs in the subscribing LiveView's own process) and must keep
  `resolve_remote?: true`, so a future fix cannot over-broaden the degrade the
  way #313 did before #319 split it back apart.
  """
  use Casein.TestCase, async: true

  alias Casein.Panes.Events

  setup do
    test = self()

    # Replace Casein.TestCase's default Manager stub with one that reports every
    # call, so we can prove whether HTTP was attempted at all.
    Req.Test.stub(Casein.Integrations.Manager.Client, fn conn ->
      send(test, {:manager_called, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    # A cold workspace: not a folder id and no persisted State record, so alias
    # resolution reaches the Workspaces.get fallthrough when remote is allowed.
    %{cold_id: "cold-ws-#{System.unique_integer([:positive])}"}
  end

  test "broadcast/1 fans out to a cold workspace without any Manager HTTP call", %{
    cold_id: cold_id
  } do
    # Subscribe to the canonical topic directly rather than via subscribe/1,
    # which would itself make the Manager call this test is asserting against.
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, Events.topic(cold_id))

    assert :ok ==
             Events.broadcast(%{
               reason: :registered,
               type: :file,
               pane_id: "pane-#{System.unique_integer([:positive])}",
               workspace_id: cold_id,
               tmux_session: nil,
               payload: %{}
             })

    # The event still reaches the canonical topic — degrading is not dropping.
    assert_receive {:pane_event, %{workspace_id: ^cold_id, reason: :registered}}

    # ...and it got there without blocking on the Manager.
    refute_received {:manager_called, _}
  end

  test "subscribe/1 stays caller-side and MAY resolve remotely", %{cold_id: cold_id} do
    # Documents the intentional asymmetry: subscribe runs in the subscribing
    # process, which owns its own request, so the remote resolve is safe there.
    # If someone "fixes" this to false, alias viewers silently stop receiving
    # pane events for cold workspaces.
    assert [_ | _] = Events.subscribe(cold_id)
    assert_received {:manager_called, _}
  end
end
