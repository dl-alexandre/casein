defmodule Casein.Mobile.TerminalChildGrant do
  @moduledoc "Digest-only, short-lived authority for one mobile-terminal connection."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "mobile_terminal_child_grants" do
    field :token_hash, :string
    field :user_id, :string
    field :device_link_id, :binary_id
    field :origin_id, :string
    field :origin_generation, :string
    field :workspace_id, :string
    field :lease_id, :binary_id
    field :lifecycle_generation, :binary_id
    field :sid, :string
    field :tmux_session, :string
    field :pane_id, :string
    field :pane_role, :string
    field :topology_generation, :string
    field :mode, :string, default: "read"
    field :connection_generation, :string
    field :begun_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :token_hash,
      :user_id,
      :device_link_id,
      :origin_id,
      :origin_generation,
      :workspace_id,
      :lease_id,
      :lifecycle_generation,
      :sid,
      :tmux_session,
      :pane_id,
      :pane_role,
      :topology_generation,
      :mode,
      :connection_generation,
      :begun_at,
      :revoked_at,
      :expires_at
    ])
    |> validate_required([
      :token_hash,
      :user_id,
      :device_link_id,
      :origin_id,
      :origin_generation,
      :workspace_id,
      :lease_id,
      :lifecycle_generation,
      :sid,
      :tmux_session,
      :pane_id,
      :pane_role,
      :topology_generation,
      :mode,
      :expires_at
    ])
    |> validate_inclusion(:mode, ["read"])
    |> validate_inclusion(:pane_role, ["mobile_terminal"])
    |> validate_length(:token_hash, is: 64)
    |> validate_length(:connection_generation, max: 160)
    |> unique_constraint(:token_hash)
  end
end
