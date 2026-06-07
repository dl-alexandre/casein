defmodule DevIDE.Previews.ControlObservation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "preview_observations" do
    field :kind, :string
    field :data, :map, default: %{}
    field :artifact_path, :string

    belongs_to :session, DevIDE.Previews.ControlSession
    belongs_to :action, DevIDE.Previews.ControlAction

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [:session_id, :action_id, :kind, :data, :artifact_path])
    |> validate_required([:session_id, :kind])
  end
end
