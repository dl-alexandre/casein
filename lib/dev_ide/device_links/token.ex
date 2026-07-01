defmodule DevIDE.DeviceLinks.Token do
  @moduledoc """
  Persistent bearer credential issued to a paired device.

  Only `token_hash` is stored. The raw token is returned once at exchange time
  and must be kept by the client.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "device_link_tokens" do
    field :origin_id, :string
    field :origin_name, :string
    field :subject_id, :string
    field :subject_email, :string
    field :subject_role, :string
    field :token_hash, :string
    field :resource_kind, :string
    field :resource_id, :string
    field :resource_label, :string
    field :capabilities, {:array, :string}, default: []
    field :device_name, :string
    field :platform, :string
    field :revoked_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :origin_id,
      :origin_name,
      :subject_id,
      :subject_email,
      :subject_role,
      :token_hash,
      :resource_kind,
      :resource_id,
      :resource_label,
      :capabilities,
      :device_name,
      :platform,
      :revoked_at,
      :last_seen_at,
      :expires_at
    ])
    |> validate_required([
      :origin_id,
      :origin_name,
      :subject_id,
      :subject_role,
      :token_hash,
      :resource_kind,
      :resource_id,
      :capabilities
    ])
    |> validate_length(:origin_id, max: 80)
    |> validate_length(:origin_name, max: 120)
    |> validate_length(:subject_id, max: 160)
    |> validate_length(:subject_email, max: 254)
    |> validate_length(:subject_role, max: 40)
    |> validate_length(:token_hash, max: 96)
    |> validate_length(:resource_kind, max: 80)
    |> validate_length(:resource_id, max: 240)
    |> validate_length(:resource_label, max: 240)
    |> validate_length(:device_name, max: 120)
    |> validate_length(:platform, max: 80)
    |> unique_constraint(:token_hash)
  end
end
