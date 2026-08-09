defmodule Casein.Inspectors.RunTest do
  use ExUnit.Case, async: true

  alias Casein.Cockpit.Inspectors
  alias Casein.Inspectors.Run

  setup do
    ws = "ws-run-#{System.unique_integer([:positive])}"
    :ok = Inspectors.subscribe(ws)
    {:ok, ws: ws}
  end

  test "surface is a no-op when nobody is watching", %{ws: ws} do
    refute Run.viewer_present?(ws)

    assert {:ok, %{status: "no_viewer", workspace_id: ^ws}} = Run.surface(ws, %{})

    assert {:ok, %{status: "no_viewer"}} = Run.surface(ws, %{run_id: "run-1"})
    refute_receive {:inspector_open, _}, 50
  end

  test "surface broadcasts inspector_open when a viewer is registered", %{ws: ws} do
    :ok = Run.register_viewer(ws)
    assert Run.viewer_present?(ws)

    assert {:ok, %{status: "surfaced", workspace_id: ^ws, run_id: "run-a", request_id: rid}} =
             Run.surface(ws, %{run_id: "run-a"})

    assert is_binary(rid)

    assert_receive {:inspector_open, attrs}, 200
    assert attrs[:kind] == :run or attrs["kind"] == :run or attrs["kind"] == "run"
    assert attrs[:run_id] == "run-a" or attrs["run_id"] == "run-a"
  end

  test "viewer registration is process-linked", %{ws: ws} do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        :ok = Run.register_viewer(ws)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 200
    assert Run.viewer_present?(ws)

    Process.exit(pid, :kill)
    wait_until(fn -> not Run.viewer_present?(ws) end)
    refute Run.viewer_present?(ws)
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, n) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, n - 1)
    end
  end
end
