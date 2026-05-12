defmodule DevIDE.Fleet.RunnerDirectoryEctoAuditTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Fleet.RunnerDirectory

  setup do
    previous_adapter = Application.get_env(:dev_ide, :audit_adapter)

    Application.put_env(:dev_ide, :audit_adapter, DevIDE.Audit.EctoAdapter)
    Audit.clear()
    RunnerDirectory.clear()

    on_exit(fn ->
      Audit.clear()
      RunnerDirectory.clear()
      Application.put_env(:dev_ide, :audit_adapter, previous_adapter)
    end)

    :ok
  end

  test "runner identity audit events are durable under the Ecto adapter" do
    assert {:ok, _identity} =
             RunnerDirectory.ensure_registered(%{
               id: "runner-ecto-audit",
               hostname: "runner-host"
             })

    assert [%{workspace_id: "fleet", action: "fleet.runner_identity.registered"}] =
             Audit.list(limit: 1)
  end
end
