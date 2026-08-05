defmodule Casein.Mobile.TerminalSession do
  @moduledoc "Durable ownership lease for one server-created disposable mobile terminal."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @states ~w(provisioning active deleting deleted expired failed)
  @role "mobile_terminal"

  schema "mobile_terminal_sessions" do
    field :user_id, :string
    field :device_link_id, :string
    field :origin_id, :string
    field :origin_generation, :string
    field :workspace_id, :string
    field :workspace_key, :string
    field :workspace_root, :string
    field :request_id, Ecto.UUID
    field :request_fingerprint, :string
    field :sid, :string
    field :tmux_session, :string
    field :tmux_native_id, :string
    field :tmux_lease_marker, :string
    field :pane_id, :string
    field :pane_role, :string, default: @role
    field :lifecycle_generation, Ecto.UUID
    field :state, :string
    field :expires_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :failure_code, :string

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
  def role, do: @role

  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :user_id,
      :device_link_id,
      :origin_id,
      :origin_generation,
      :workspace_id,
      :workspace_key,
      :workspace_root,
      :request_id,
      :request_fingerprint,
      :sid,
      :tmux_session,
      :pane_role,
      :lifecycle_generation,
      :state,
      :expires_at
    ])
    |> validate_required([
      :user_id,
      :device_link_id,
      :origin_id,
      :origin_generation,
      :workspace_id,
      :workspace_key,
      :workspace_root,
      :request_id,
      :request_fingerprint,
      :sid,
      :tmux_session,
      :pane_role,
      :lifecycle_generation,
      :state,
      :expires_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_format(:sid, ~r/\Amob-[0-9a-f-]{36}\z/)
    |> validate_inclusion(:pane_role, [@role])
    |> validate_length(:request_fingerprint, is: 64)
    |> validate_length(:user_id, max: 160)
    |> validate_length(:device_link_id, max: 160)
    |> validate_length(:origin_id, max: 160)
    |> validate_length(:origin_generation, max: 160)
    |> validate_length(:workspace_id, max: 240)
    |> validate_length(:workspace_key, max: 240)
    |> validate_length(:workspace_root, max: 2_048)
    |> validate_length(:tmux_session, max: 512)
    |> unique_constraint([:device_link_id, :request_id],
      name: :mobile_terminal_sessions_device_request_index
    )
    |> unique_constraint(:tmux_session)
  end

  def transition_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :state,
      :pane_id,
      :tmux_native_id,
      :tmux_lease_marker,
      :ended_at,
      :failure_code
    ])
    |> validate_required([:state])
    |> validate_inclusion(:state, @states)
    |> validate_length(:pane_id, max: 32)
    |> validate_length(:tmux_native_id, max: 64)
    |> validate_length(:tmux_lease_marker, max: 64)
    |> validate_length(:failure_code, max: 80)
  end
end
