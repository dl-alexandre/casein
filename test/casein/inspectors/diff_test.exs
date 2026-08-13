defmodule Casein.Inspectors.DiffTest do
  use ExUnit.Case, async: true

  alias Casein.Cockpit.Inspectors
  alias Casein.Inspectors.Diff

  setup do
    ws = "ws-diff-#{System.unique_integer([:positive])}"
    :ok = Inspectors.subscribe(ws)
    {:ok, ws: ws}
  end

  test "surface is a no-op when nobody is watching", %{ws: ws} do
    refute Diff.viewer_present?(ws)

    assert {:ok, %{status: "no_viewer", workspace_id: ^ws}} = Diff.surface(ws, %{})

    # Nothing was queued — a second call is still no_viewer and no broadcast.
    assert {:ok, %{status: "no_viewer"}} = Diff.surface(ws, %{path: "lib/foo.ex"})
    refute_receive {:inspector_open, _}, 50
  end

  test "surface broadcasts inspector_open when a viewer is registered", %{ws: ws} do
    :ok = Diff.register_viewer(ws)
    assert Diff.viewer_present?(ws)

    assert {:ok, %{status: "surfaced", workspace_id: ^ws, path: "lib/a.ex", request_id: rid}} =
             Diff.surface(ws, %{path: "lib/a.ex"})

    assert is_binary(rid)

    assert_receive {:inspector_open, attrs}, 200
    assert attrs[:kind] == :diff or attrs["kind"] == :diff or attrs["kind"] == "diff"
    assert attrs[:path] == "lib/a.ex" or attrs["path"] == "lib/a.ex"
  end

  test "viewer registration is process-linked", %{ws: ws} do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        :ok = Diff.register_viewer(ws)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 200
    assert Diff.viewer_present?(ws)

    Process.exit(pid, :kill)

    Casein.Test.Eventually.await(
      fn -> not Diff.viewer_present?(ws) && true end,
      timeout_ms: 500,
      interval_ms: 10,
      message: "diff inspector viewer was still registered after the owner exited"
    )

    refute Diff.viewer_present?(ws)
  end
end
