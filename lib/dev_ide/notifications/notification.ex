defmodule DevIDE.Notifications.Notification do
  @moduledoc """
  Durable user-facing notification row.

  This is the stable inbox contract. Delivery surfaces such as in-app LiveView,
  browser notifications, mobile cards, and OS push can all render from this
  shape without owning notification policy themselves.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @severities ~w(info warning error critical)
  @channels ~w(in_app push browser mobile digest)

  schema "notifications" do
    field :user_id, :string
    field :workspace_id, :string
    field :session_id, :string
    field :type, :string
    field :severity, :string, default: "info"
    field :title, :string
    field :body, :string
    field :metadata, :map, default: %{}
    field :dedupe_key, :string
    field :ttl_seconds, :integer
    field :expires_at, :utc_datetime_usec
    field :deep_link, :string
    field :channels, DevIDE.EctoTypes.StringList, default: []
    field :default_delivery, :map, default: %{}
    field :source_type, :string
    field :source_id, :string
    field :read_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :muted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(notification, attrs) do
    attrs = normalize_attrs(attrs || %{})

    notification
    |> cast(attrs, [
      :user_id,
      :workspace_id,
      :session_id,
      :type,
      :severity,
      :title,
      :body,
      :metadata,
      :dedupe_key,
      :ttl_seconds,
      :expires_at,
      :deep_link,
      :channels,
      :default_delivery,
      :source_type,
      :source_id,
      :read_at,
      :resolved_at,
      :muted_at
    ])
    |> validate_required([:user_id, :type, :severity, :title])
    |> validate_inclusion(:severity, @severities)
    |> validate_channel_subset(:channels, @channels)
    |> validate_number(:ttl_seconds, greater_than: 0)
    |> validate_length(:user_id, max: 240)
    |> validate_length(:workspace_id, max: 240)
    |> validate_length(:session_id, max: 240)
    |> validate_length(:type, max: 120)
    |> validate_length(:title, max: 240)
    |> validate_length(:dedupe_key, max: 512)
    |> validate_length(:source_type, max: 120)
    |> validate_length(:source_id, max: 240)
    |> normalize_json_field(:metadata)
    |> normalize_json_field(:default_delivery)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_string_value(:severity)
    |> normalize_string_value(:type)
    |> normalize_string_value(:source_type)
    |> normalize_channels()
  end

  defp normalize_string_value(attrs, key) do
    update_existing(attrs, key, fn
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end)
  end

  defp normalize_channels(attrs) do
    update_existing(attrs, :channels, fn
      values when is_list(values) -> Enum.map(values, &string_value/1)
      value -> value
    end)
  end

  defp update_existing(attrs, key, fun) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.update!(attrs, key, fun)
      Map.has_key?(attrs, string_key) -> Map.update!(attrs, string_key, fun)
      true -> attrs
    end
  end

  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: value

  defp validate_channel_subset(changeset, field, allowed) do
    validate_change(changeset, field, fn ^field, values ->
      invalid =
        values
        |> List.wrap()
        |> Enum.reject(&(&1 in allowed))

      if invalid == [], do: [], else: [{field, "contains unsupported channels"}]
    end)
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
