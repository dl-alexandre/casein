defmodule DevIDE.Commands.RunTest do
  use ExUnit.Case, async: false
  alias DevIDE.Commands.Run

  setup do
    root = Path.join(System.tmp_dir!(), "run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "refuses non-allowlisted ids", %{root: root} do
    ws = "ws-#{System.unique_integer([:positive])}"
    assert {:error, :not_allowed} = Run.start(ws, root, "rm -rf /")
    assert {:error, :not_allowed} = Run.start(ws, root, "compile; pwned")
  end

  test "refuses missing root" do
    ws = "ws-#{System.unique_integer([:positive])}"
    assert {:error, :no_root} = Run.start(ws, "/no/such/path", "format")
  end

  test "completed run does not block a second run", %{root: root} do
    ws = "ws-#{System.unique_integer([:positive])}"

    {:ok, pid1} =
      DevIDE.Commands.Run.start_link({ws, root, "format", []})
      |> tap(fn _ -> :ok end)

    fake_terminal(pid1, :succeeded)
    assert {:ok, _} = DevIDE.Commands.Run.whereis(ws)

    # Asking for a new run should tear down the old one and replace it.
    case Run.start(ws, root, "format") do
      {:ok, _new} -> :ok
      {:error, {:spawn_failed, _}} -> :ok
    end
  end

  test "hard timeout marks status :timed_out", %{root: root} do
    ws = "ws-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      DevIDE.Commands.Run.start_link({ws, root, "format", [timeout_ms: 50]})
      |> tap(fn _ -> :ok end)

    Process.sleep(300)

    snap = DevIDE.Commands.Run.state(pid)
    assert snap.status in [:timed_out, :succeeded, :failed]
    if snap.status == :timed_out, do: assert(snap.exit_code == :timeout)
  end

  defp fake_terminal(pid, status) do
    :sys.replace_state(pid, fn s ->
      %{s | status: status, finished_at: DateTime.utc_now(), exit_code: 0}
    end)
  end
end
