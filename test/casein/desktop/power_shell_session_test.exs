defmodule Casein.Desktop.PowerShellSessionTest do
  use ExUnit.Case, async: false

  alias Casein.Desktop.PowerShellSession

  @moduletag :pty

  test "native topology validates pane targets and retains capture across subscribers" do
    session_name = :"native-topology-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!({PowerShellSession, cwd: File.cwd!(), workspace: nil, name: session_name})

    topology = GenServer.call(pid, :topology)

    assert %{session: %{id: session_id, workspace_id: "__scratch__", alive?: true}} = topology

    assert %{windows: [%{id: window_id, session_id: ^session_id, index: 0, active?: true}]} =
             topology

    assert %{
             panes: [
               %{
                 id: pane_id,
                 window_id: ^window_id,
                 index: 0,
                 role: "operator",
                 cols: 100,
                 rows: 30
               }
             ]
           } = topology

    assert {:error, :invalid_pane_target} =
             GenServer.call(pid, {:capture, pane_id <> "-unknown"})

    assert {:error, :invalid_terminal_size} =
             GenServer.call(pid, {:resize, pane_id, 0, 30})

    assert {:error, :invalid_pane_role} =
             GenServer.call(pid, {:set_pane_role, pane_id, "operator; Remove-Item"})

    assert :ok = GenServer.call(pid, {:set_pane_role, pane_id, "agent"})
    assert :ok = GenServer.call(pid, {:resize, pane_id, 132, 44})
    assert %{panes: [%{role: "agent", cols: 132, rows: 44}]} = GenServer.call(pid, :topology)

    assert {:ok, _term, pty, :running} = GenServer.call(pid, {:subscribe, self()})
    marker = "CASEIN_NATIVE_CAPTURE_#{System.unique_integer([:positive])}"
    assert :ok = Ghostty.PTY.write(pty, "Write-Output #{marker}\r")
    assert receive_output(marker) =~ marker
    _ = :sys.get_state(pid)
    assert {:ok, capture} = GenServer.call(pid, {:capture, pane_id})
    assert capture =~ marker
  end

  test "native sessions have independent workspace-scoped process ownership" do
    registry = PowerShellSession.Registry
    supervisor = PowerShellSession.Supervisor

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor})

    alpha = %{id: "desktop-alpha", name: "Alpha"}
    beta = %{id: "desktop-beta", name: "Beta"}

    # Agent materialization is covered separately; this transport test keeps the
    # native shells credential-free while proving that their owners are distinct.
    alpha_name = {:via, Registry, {registry, alpha.id}}
    beta_name = {:via, Registry, {registry, beta.id}}

    {:ok, alpha_pid} =
      DynamicSupervisor.start_child(
        supervisor,
        {PowerShellSession, cwd: File.cwd!(), workspace: nil, name: alpha_name}
      )

    {:ok, beta_pid} =
      DynamicSupervisor.start_child(
        supervisor,
        {PowerShellSession, cwd: File.cwd!(), workspace: nil, name: beta_name}
      )

    assert alpha_pid != beta_pid
    assert [{^alpha_pid, _}] = Registry.lookup(registry, alpha.id)
    assert [{^beta_pid, _}] = Registry.lookup(registry, beta.id)

    assert {:ok, alpha_term, alpha_pty, :running} =
             GenServer.call(alpha_name, {:subscribe, self()})

    assert {:ok, beta_term, beta_pty, :running} = GenServer.call(beta_name, {:subscribe, self()})
    assert alpha_term != beta_term
    assert alpha_pty != beta_pty
  end

  defp receive_output(marker, output \\ "") do
    if output =~ marker do
      output
    else
      receive do
        {:desktop_terminal_output, data} -> receive_output(marker, output <> data)
      after
        5_000 -> flunk("timed out waiting for native terminal output: #{inspect(output)}")
      end
    end
  end
end
