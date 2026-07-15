defmodule DevIDE.Factory do
  @moduledoc """
  Shared ExMachina factories for Ecto-backed domain rows.

  Prefer factories for persisted records; keep behaviour-backed fakes
  (`FakeTmuxAdapter`, etc.) for IO boundaries.
  """

  use Boundary,
    top_level?: true,
    check: [in: false, out: false]

  use ExMachina.Ecto, repo: DevIDE.Repo

  alias DevIDE.Audit.EctoAdapter, as: AuditEcto
  alias DevIDE.Workspaces.State.EctoAdapter, as: WorkspaceEcto

  def workspace_record_factory do
    external_id = sequence(:workspace_external_id, &"ws-#{&1}")

    %WorkspaceEcto.Row{
      external_id: external_id,
      name: sequence(:workspace_name, &"workspace-#{&1}"),
      host_path: "/tmp/#{external_id}",
      status: "running",
      mode: "review",
      manager_payload: %{},
      last_seen_at: DateTime.utc_now()
    }
  end

  def audit_event_factory do
    %AuditEcto.Row{
      id: Ecto.UUID.generate(),
      workspace_id: sequence(:audit_workspace_id, &"ws-#{&1}"),
      actor_id: "test-actor",
      action: "test.action",
      target_type: "file",
      target_ref: "lib/example.ex",
      decision: "allow",
      reason: nil,
      metadata: %{},
      inserted_at: DateTime.utc_now()
    }
  end
end
