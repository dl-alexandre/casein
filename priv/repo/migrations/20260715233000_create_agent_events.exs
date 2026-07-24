defmodule Casein.Repo.Migrations.CreateAgentEvents do
  use Ecto.Migration

  def change do
    create table(:agent_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :text, null: false
      add :stream_id, :text, null: false
      add :producer, :text, null: false
      add :ingress, :text, null: false
      add :source_event_id, :text, null: false
      add :source_sequence, :bigint
      add :event_type, :text, null: false
      add :privacy_class, :text, null: false, default: "metadata"
      add :agent_session_id, :text
      add :tmux_session_id, :text
      add :pane_id, :text
      add :runtime_id, :text
      add :actor_id, :text
      add :status, :text
      add :summary, :text, null: false, default: ""
      add :correlation_id, :text
      add :causation_id, :text
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:agent_events, [:workspace_id, "occurred_at desc", "inserted_at desc"],
             name: :agent_events_workspace_occurred_idx
           )

    create index(:agent_events, [:workspace_id, "inserted_at asc", "id asc"],
             name: :agent_events_workspace_inserted_idx
           )

    create index(
             :agent_events,
             [:workspace_id, :agent_session_id, "occurred_at desc"],
             name: :agent_events_agent_session_idx,
             where: "agent_session_id IS NOT NULL"
           )

    create index(:agent_events, [:workspace_id, :stream_id, :source_sequence],
             name: :agent_events_stream_sequence_idx,
             where: "source_sequence IS NOT NULL"
           )

    create index(
             :agent_events,
             [:workspace_id, :tmux_session_id, :pane_id, "occurred_at desc"],
             name: :agent_events_tmux_pane_idx,
             where: "tmux_session_id IS NOT NULL"
           )

    create index(:agent_events, [:correlation_id, "occurred_at asc"],
             name: :agent_events_correlation_idx,
             where: "correlation_id IS NOT NULL"
           )

    create unique_index(:agent_events, [:workspace_id, :stream_id, :source_event_id],
             name: :agent_events_stream_source_event_id_idx
           )
  end
end
