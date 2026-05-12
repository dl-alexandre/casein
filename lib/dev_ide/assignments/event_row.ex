defmodule DevIDE.Assignments.EventRow do
  @moduledoc "Ecto schema for the `assignment_events` table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "assignment_events" do
    field :assignment_id, :string
    field :sequence, :integer
    field :type, :string
    field :actor, :string
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:id, :assignment_id, :sequence, :type, :actor, :payload, :occurred_at])
    |> validate_required([:assignment_id, :sequence, :type, :occurred_at])
  end
end
