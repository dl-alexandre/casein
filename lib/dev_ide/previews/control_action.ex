defmodule DevIDE.Previews.ControlAction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "preview_actions" do
    field :action, :string
    field :params, :map, default: %{}
    field :result, :map, default: %{}
    field :status, Ecto.Enum, values: [:ok, :error]
    field :actor_id, :string
    field :assignment_id, :string

    belongs_to :session, DevIDE.Previews.ControlSession
    has_many :observations, DevIDE.Previews.ControlObservation, foreign_key: :action_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [:session_id, :action, :params, :result, :status, :actor_id, :assignment_id])
    |> validate_required([:session_id, :action])
    |> put_default_status()
  end

  defp put_default_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, :ok)
      _ -> changeset
    end
  end
end
