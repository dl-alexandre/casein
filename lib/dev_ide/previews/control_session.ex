defmodule DevIDE.Previews.ControlSession do
  use Ecto.Schema
  import Ecto.Changeset

  schema "preview_control_sessions" do
    field :workspace_id, :string
    field :surface, :string
    field :adapter, :string
    field :status, Ecto.Enum, values: [:open, :closed, :error]
    field :current_url, :string
    field :actor_id, :string
    field :assignment_id, :string
    field :metadata, :map, default: %{}

    belongs_to :preview, DevIDE.Previews.Preview
    has_many :actions, DevIDE.Previews.ControlAction, foreign_key: :session_id
    has_many :observations, DevIDE.Previews.ControlObservation, foreign_key: :session_id

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :workspace_id,
      :preview_id,
      :surface,
      :adapter,
      :status,
      :current_url,
      :actor_id,
      :assignment_id,
      :metadata
    ])
    |> validate_required([:workspace_id, :surface, :adapter])
    |> put_default_status()
  end

  defp put_default_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, :open)
      _ -> changeset
    end
  end
end
