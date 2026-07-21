defmodule DevIDE.Desktop.PowerShellSessionTest do
  use ExUnit.Case, async: false

  alias DevIDE.Desktop.PowerShellSession

  @moduletag :pty

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
end
