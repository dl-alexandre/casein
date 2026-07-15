defmodule DevIDE.Repo.Migrations.AddAuditEventsCorrelationIndex do
  @moduledoc """
  Expression index for `DevIDE.Audit.list_by_correlation/1`: causality
  correlation ids live in the metadata JSONB (stamped by
  `DevIDE.Signals.Context`), and provenance queries filter on
  `metadata->>'correlation_id'`.
  """
  use Ecto.Migration

  def change do
    create index(:audit_events, ["(metadata->>'correlation_id')"],
             name: :audit_events_correlation_id_idx
           )
  end
end
