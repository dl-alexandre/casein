defmodule DevIDE.Notifications.Preference do
  @moduledoc """
  Per-user notification routing preferences.

  Global preferences use `workspace_id == "__global__"` so the database can
  enforce one row per user without relying on NULL uniqueness behavior.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @global_workspace_id "__global__"

  schema "notification_preferences" do
    field :user_id, :string
    field :workspace_id, :string, default: @global_workspace_id
    field :settings, :map, default: %{}
    field :quiet_hours, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def global_workspace_id, do: @global_workspace_id

  @doc false
  def changeset(preference, attrs) do
    attrs = normalize_attrs(attrs || %{})

    preference
    |> cast(attrs, [:user_id, :workspace_id, :settings, :quiet_hours])
    |> validate_required([:user_id, :workspace_id])
    |> validate_length(:user_id, max: 240)
    |> validate_length(:workspace_id, max: 240)
    |> normalize_json_field(:settings)
    |> normalize_json_field(:quiet_hours)
    |> unique_constraint([:user_id, :workspace_id],
      name: :notification_preferences_user_id_workspace_id_index
    )
  end

  defp normalize_attrs(attrs) do
    workspace_id = Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id")

    if workspace_id in [nil, ""] do
      put_attr(attrs, :workspace_id, @global_workspace_id)
    else
      attrs
    end
  end

  defp put_attr(attrs, key, value) do
    if Map.has_key?(attrs, Atom.to_string(key)),
      do: Map.put(attrs, Atom.to_string(key), value),
      else: Map.put(attrs, key, value)
  end

  defp normalize_json_field(changeset, field) do
    update_change(changeset, field, fn
      value when is_map(value) -> normalize_json_map(value)
      _ -> %{}
    end)
  end

  defp normalize_json_map(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  rescue
    _ -> %{}
  end
end
