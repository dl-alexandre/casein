defmodule DevIDE.Runtimes.HostRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "runtime_hosts" do
    field :os, :string
    field :capabilities, DevIDE.EctoTypes.StringList, default: []
    field :tools, DevIDE.EctoTypes.StringList, default: []
    field :concurrency_limit, :integer, default: 1
    field :heartbeat_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
end
