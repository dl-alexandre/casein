defmodule Casein.DeviceLinks.PairingHandle do
  @moduledoc """
  Server-owned, single-use state behind a compact mobile pairing QR.

  The QR contains the raw opaque handle once. Only its SHA-256 hash is stored,
  while user, origin, workspace, audience, capability, and expiry bindings stay
  authoritative on the server.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "device_link_pairing_handles" do
    field :handle_hash, :string
    field :origin_id, :string
    field :origin_base_url, :string
    field :subject_id, :string
    field :subject_email, :string
    field :subject_role, :string
    field :resource_kind, :string
    field :resource_id, :string
    field :resource_label, :string
    field :capabilities, {:array, :string}, default: []
    field :audience, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(handle, attrs) do
    handle
    |> cast(attrs, [
      :handle_hash,
      :origin_id,
      :origin_base_url,
      :subject_id,
      :subject_email,
      :subject_role,
      :resource_kind,
      :resource_id,
      :resource_label,
      :capabilities,
      :audience,
      :expires_at,
      :consumed_at,
      :revoked_at
    ])
    |> validate_required([
      :handle_hash,
      :origin_id,
      :origin_base_url,
      :subject_id,
      :subject_role,
      :resource_kind,
      :resource_id,
      :capabilities,
      :audience,
      :expires_at
    ])
    |> validate_length(:handle_hash, max: 96)
    |> validate_length(:origin_id, max: 80)
    |> validate_length(:origin_base_url, max: 512)
    |> validate_length(:subject_id, max: 160)
    |> validate_length(:subject_email, max: 254)
    |> validate_length(:subject_role, max: 40)
    |> validate_length(:resource_kind, max: 80)
    |> validate_length(:resource_id, max: 240)
    |> validate_length(:resource_label, max: 240)
    |> validate_length(:audience, max: 80)
    |> unique_constraint(:handle_hash)
  end
end
