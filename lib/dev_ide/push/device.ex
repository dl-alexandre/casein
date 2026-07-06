defmodule DevIDE.Push.Device do
  @moduledoc """
  Persistent OS/browser push registration.

  `scope` is either `"workspace"` for workspace audit alerts or `"user"` for
  mobile-card/user notifications. The raw token is still required for delivery;
  `token_hash` is the stable lookup key used for unregister/failure updates.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @scopes ~w(workspace user)
  @statuses ~w(active invalid disabled failed)

  schema "push_devices" do
    field :token_hash, :string
    field :token, :string
    field :platform, :string
    field :scope, :string
    field :scope_id, :string
    field :user_id, :string
    field :workspace_id, :string
    field :device_link_id, :string
    field :push_subscription, :map, default: %{}
    field :last_seen_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :failure_count, :integer, default: 0
    field :provider_status, :string, default: "active"

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(device, attrs) do
    attrs = normalize_attrs(attrs || %{})

    device
    |> cast(attrs, [
      :token_hash,
      :token,
      :platform,
      :scope,
      :scope_id,
      :user_id,
      :workspace_id,
      :device_link_id,
      :push_subscription,
      :last_seen_at,
      :disabled_at,
      :failure_count,
      :provider_status
    ])
    |> validate_required([:token_hash, :token, :platform, :scope, :scope_id, :last_seen_at])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:provider_status, @statuses)
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
    |> validate_length(:token_hash, is: 64)
    |> validate_length(:token, max: 4096)
    |> validate_length(:platform, max: 80)
    |> validate_length(:scope, max: 40)
    |> validate_length(:scope_id, max: 240)
    |> validate_length(:user_id, max: 240)
    |> validate_length(:workspace_id, max: 240)
    |> validate_length(:device_link_id, max: 240)
    |> normalize_json_field(:push_subscription)
    |> unique_constraint([:token_hash, :scope, :scope_id],
      name: :push_devices_token_hash_scope_scope_id_index
    )
  end

  defp normalize_attrs(attrs) do
    attrs
    |> normalize_string_value(:platform)
    |> normalize_string_value(:scope)
    |> normalize_string_value(:provider_status)
  end

  defp normalize_string_value(attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.update!(attrs, key, &to_string_value/1)
      Map.has_key?(attrs, string_key) -> Map.update!(attrs, string_key, &to_string_value/1)
      true -> attrs
    end
  end

  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(value), do: value

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
