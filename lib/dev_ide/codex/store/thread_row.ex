defmodule Casein.Codex.Store.ThreadRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:thread_id, :string, autogenerate: false}
  schema "codex_threads" do
    field :workspace_id, :string
    field :runtime_id, :string
    field :parent_thread_id, :string
    field :session_id, :string
    field :transport, :string
    field :status, :string
    field :active_flags, :map, default: %{}
    field :current_turn_id, :string
    field :agent_role, :string
    field :agent_nickname, :string
    field :preview, :string
    field :usage, :map, default: %{}
    field :last_sequence, :integer
    field :last_event_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
end
