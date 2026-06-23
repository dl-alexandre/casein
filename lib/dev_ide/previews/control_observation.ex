defmodule DevIDE.Previews.ControlObservation do
  @moduledoc """
  Ecto schema for a captured observation of a `ControlSession` — a typed `kind`
  (url, dom_summary, console_errors, network_errors, storage, screenshot) with
  its data and optional artifact path, linked to the action that produced it.
  """
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
