defmodule DevIde.FactoryTest do
  use DevIde.DataCase, async: true

  alias DevIDE.Audit.EctoAdapter, as: AuditEcto
  alias DevIDE.Workspaces.State.EctoAdapter, as: WorkspaceEcto

  test "workspace_record factory persists a row" do
    row = insert(:workspace_record)

    assert %WorkspaceEcto.Row{} = Repo.get!(WorkspaceEcto.Row, row.id)
    assert row.external_id =~ "ws-"
    assert row.status == "running"
  end

  test "audit_event factory persists a row" do
    row = insert(:audit_event)

    assert %AuditEcto.Row{} = Repo.get!(AuditEcto.Row, row.id)
    assert row.action == "test.action"
  end
end
