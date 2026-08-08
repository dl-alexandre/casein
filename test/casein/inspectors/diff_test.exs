defmodule Casein.Inspectors.DiffTest do
  use ExUnit.Case, async: true

  alias Casein.Inspectors.Diff

  setup do
    ws = "ws-diff-#{System.unique_integer([:positive])}"
    {:ok, ws: ws}
  end

  test "surface is a no-op when nobody is watching", %{ws: ws} do
    refute Diff.viewer_present?(ws)

    assert {:ok, %{status: "no_viewer", workspace_id: ^ws}} = Diff.surface(ws, %{})

    # Nothing was queued for a later viewer — a second call is still no_viewer.
    assert {:ok, %{status: "no_viewer"}} = Diff.surface(ws, %{path: "lib/foo.ex"})
  end

  test "surface broadcasts when a viewer is registered", %{ws: ws} do
    :ok = Diff.subscribe(ws)
    :ok = Diff.register_viewer(ws)
    assert Diff.viewer_present?(ws)

    assert {:ok, %{status: "surfaced", workspace_id: ^ws, path: "lib/a.ex", request_id: rid}} =
             Diff.surface(ws, %{path: "lib/a.ex"})

    assert is_binary(rid)

    assert_receive {:surface_diff, %{workspace_id: ^ws, path: "lib/a.ex", request_id: ^rid}},
                   200
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
    # Registry drops dead processes on next lookup after DOWN.
    wait_until(fn -> not Diff.viewer_present?(ws) end)
    refute Diff.viewer_present?(ws)
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
