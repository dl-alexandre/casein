defmodule Casein.Agents.AgentEvent do
  @moduledoc """
  Durable, normalized event in an agent session timeline.

  Payloads are metadata-only by default. Raw prompts, transcript text, tool
  input/output, thoughts, and code belong in their source systems rather than
  this projection.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @type t :: %__MODULE__{}

  schema "agent_events" do
    field :workspace_id, :string
    field :stream_id, :string
    field :producer, :string
    field :ingress, :string
    field :source_event_id, :string
    field :source_sequence, :integer
    field :event_type, :string
    field :privacy_class, :string, default: "metadata"
    field :agent_session_id, :string
    field :tmux_session_id, :string
    field :pane_id, :string
    field :runtime_id, :string
    field :actor_id, :string
    field :status, :string
    field :summary, :string, default: ""
    field :correlation_id, :string
    field :causation_id, :string
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps()
  end

  @fields [
    :id,
    :workspace_id,
    :stream_id,
    :producer,
    :ingress,
    :source_event_id,
    :source_sequence,
    :event_type,
    :privacy_class,
    :agent_session_id,
    :tmux_session_id,
    :pane_id,
    :runtime_id,
    :actor_id,
    :status,
    :summary,
    :correlation_id,
    :causation_id,
    :payload,
    :occurred_at,
    :inserted_at
  ]

  @required [
    :workspace_id,
    :stream_id,
    :producer,
    :ingress,
    :source_event_id,
    :event_type,
    :privacy_class,
    :occurred_at,
    :inserted_at
  ]

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_length(:workspace_id, max: 240)
    |> validate_length(:stream_id, max: 500)
    |> validate_length(:producer, max: 80)
    |> validate_length(:ingress, max: 80)
    |> validate_length(:source_event_id, max: 500)
    |> validate_length(:event_type, max: 160)
    |> validate_inclusion(:privacy_class, ["metadata", "operator_content"])
    |> validate_length(:agent_session_id, max: 240)
    |> validate_length(:tmux_session_id, max: 240)
    |> validate_length(:pane_id, max: 120)
    |> validate_length(:runtime_id, max: 240)
    |> validate_length(:actor_id, max: 240)
    |> validate_length(:status, max: 80)
    |> validate_length(:summary, max: 500)
    |> validate_length(:correlation_id, max: 240)
    |> validate_length(:causation_id, max: 240)
    |> unique_constraint([:workspace_id, :stream_id, :source_event_id],
      name: :agent_events_stream_source_event_id_idx
    )
  end
end
