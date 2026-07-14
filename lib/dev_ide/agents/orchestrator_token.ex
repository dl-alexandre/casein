defmodule DevIDE.Agents.OrchestratorToken do
  @moduledoc """
  A self-serve, subject-attributed MCP bearer credential.

  Minted by an authenticated cockpit user for connecting an off-box agent. Only
  `token_hash` is stored — the raw token is returned once at mint time. Unlike a
  per-workspace `DevIDE.Agents.WorkspaceTokens` token, this credential traverses
  every workspace (like the global token) but is revocable, TTL'd, hashed at
  rest, and attributable to a subject — never the root env secret. See
  `DevIDE.Agents.OrchestratorTokens`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "orchestrator_api_tokens" do
    field :token_hash, :string
    field :subject_id, :string
    field :subject_email, :string
    field :subject_role, :string
    field :label, :string
    field :revoked_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :subject_id,
      :subject_email,
      :subject_role,
      :label,
      :revoked_at,
      :last_seen_at,
      :expires_at
    ])
    |> validate_required([:token_hash, :subject_id, :subject_role, :expires_at])
    |> validate_length(:token_hash, max: 96)
    |> validate_length(:subject_id, max: 160)
    |> validate_length(:subject_email, max: 254)
    |> validate_length(:subject_role, max: 40)
    |> validate_length(:label, max: 120)
    |> unique_constraint(:token_hash)
  end
end
