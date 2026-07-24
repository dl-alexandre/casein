defmodule Casein.Previews.ControlSession do
  @moduledoc """
  Ecto schema for one browser/control runtime attached to a `Preview`. Records
  the adapter, current URL, actor/assignment, storage profile metadata, and
  open/closed/error status; owns `has_many` actions and observations.
  """
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

    belongs_to :preview, Casein.Previews.Preview
    has_many :actions, Casein.Previews.ControlAction, foreign_key: :session_id
    has_many :observations, Casein.Previews.ControlObservation, foreign_key: :session_id

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
