defmodule Casein.Agents.McpTicket do
  @moduledoc """
  Hash-at-rest, single-use authorization for one MCP surface and workspace.

  The server-owned row freezes a subset of an existing agent capability. The
  opaque raw ticket is returned once and is never persisted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,239}\z/
  @tool_name ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}\z/
  @surfaces ~w(terminal preview artifact)

  schema "mcp_tickets" do
    field :ticket_hash, :string
    field :capability_id, Ecto.UUID
    field :workspace_id, :string
    field :surface, :string
    field :scopes, {:array, :string}, default: []
    field :runtime, :string
    field :tmux_session_id, :string
    field :pane_id, :string
    field :leader_id, :string
    field :bundle_digest, :string
    field :workspace_mode, :string
    field :checkout_digest, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :ticket_hash,
      :capability_id,
      :workspace_id,
      :surface,
      :scopes,
      :runtime,
      :tmux_session_id,
      :pane_id,
      :leader_id,
      :bundle_digest,
      :workspace_mode,
      :checkout_digest,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([
      :ticket_hash,
      :capability_id,
      :workspace_id,
      :surface,
      :scopes,
      :runtime,
      :expires_at
    ])
    |> validate_length(:ticket_hash, max: 96)
    |> validate_format(:workspace_id, @identifier)
    |> validate_inclusion(:surface, @surfaces)
    |> validate_inclusion(:runtime, ["grok"])
    |> validate_scopes()
    |> unique_constraint(:ticket_hash)
  end

  defp validate_scopes(changeset) do
    scopes = get_field(changeset, :scopes)

    if is_list(scopes) and scopes != [] and length(scopes) <= 128 and
         length(Enum.uniq(scopes)) == length(scopes) and
         Enum.all?(scopes, &(is_binary(&1) and Regex.match?(@tool_name, &1))) do
      changeset
    else
      add_error(changeset, :scopes, "must be unique exact MCP tool names")
    end
  end
end
