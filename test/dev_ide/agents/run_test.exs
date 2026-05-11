defmodule DevIDE.Agents.RunTest do
  use ExUnit.Case, async: false
  alias DevIDE.Agents.{Run, Capability}

  setup do
    root = Path.join(System.tmp_dir!(), "ar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "non-allowlisted id rejected", %{root: root} do
    ws = "ws-#{System.unique_integer([:positive])}"
    assert {:error, :not_allowed} = Run.start(ws, root, "rm -rf /", [])
    assert {:error, :not_allowed} = Run.start(ws, root, "opencode-pwn", [])
  end

  test "missing requires rejected", %{root: root} do
    ws = "ws-#{System.unique_integer([:positive])}"
    # No detected opencode capability
    assert {:error, :requires_not_met} = Run.start(ws, root, "opencode-version", [])

    assert {:error, :requires_not_met} =
             Run.start(ws, root, "opencode-version", [
               %Capability{kind: :opencode, status: :missing}
             ])
  end

  test "missing root rejected even when requires met" do
    ws = "ws-#{System.unique_integer([:positive])}"

    assert {:error, :no_root} =
             Run.start(ws, "/no/such/path", "opencode-version", [
               %Capability{kind: :opencode, status: :detected}
             ])
  end
end
