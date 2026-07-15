defmodule DevIDE.Agents.OrchestratorTokens do
  @moduledoc """
  Self-serve, subject-attributed MCP bearer tokens for connecting off-box agents.

  A minted token traverses every workspace like the global token, but — unlike
  the root env secret — it is hashed at rest (only the SHA-256 is stored), TTL'd,
  revocable, and attributable to the cockpit user who minted it. It resolves in
  `DevIdeWeb.Plugs.ApiAuth` to a `{:orchestrator, subject}` scope: non-global, so
  `DevIdeWeb.Endpoint.reject_global_mcp_tool_calls/2` does not block its
  `tools/call` and it needs no `DEV_IDE_ALLOW_GLOBAL_MCP_TOOL_CALLS` flag.

  Storage/lifecycle mirrors `DevIDE.DeviceLinks` (hash-at-rest + TTL + revoke +
  subject-scoped list + reaper GC). The raw token is returned exactly once, at
  mint time.
  """

  import Ecto.Query

  alias DevIDE.Agents.OrchestratorToken
  alias DevIDE.Repo

  @default_ttl_seconds 60 * 60 * 24 * 30

  @type claims :: %{
          subject_id: String.t(),
          subject_email: String.t() | nil,
          subject_role: String.t()
        }

  @doc """
  Mint a token for the authenticated cockpit `user`. Returns `{:ok, raw_token,
  record}` — the raw token is shown once and never persisted.
  """
  @spec create_for_subject(map(), keyword()) ::
          {:ok, String.t(), OrchestratorToken.t()} | {:error, Ecto.Changeset.t()}
  def create_for_subject(user, opts \\ []) when is_map(user) do
    raw_token = generate_token()
    now = DateTime.utc_now()

    attrs = %{
      token_hash: token_hash(raw_token),
      subject_id: subject_id(user),
      subject_email: user[:email] || user["email"],
      subject_role: role_to_string(user[:role] || user["role"]),
      label: opts |> Keyword.get(:label) |> normalize_label(),
      expires_at: DateTime.add(now, ttl_seconds(), :second)
    }

    case %OrchestratorToken{} |> OrchestratorToken.changeset(attrs) |> Repo.insert() do
      {:ok, record} -> {:ok, raw_token, record}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verify a raw bearer. Returns `{:ok, claims}` for an active token (touching
  `last_seen_at`), else `{:error, :missing | :invalid_token | :revoked | :expired}`.
  """
  @spec verify(String.t()) :: {:ok, claims()} | {:error, atom()}
  def verify(raw_token) when is_binary(raw_token) do
    case String.trim(raw_token) do
      "" -> {:error, :missing}
      trimmed -> trimmed |> token_hash() |> fetch() |> verify_record(DateTime.utc_now())
    end
  end

  def verify(_raw_token), do: {:error, :missing}

  @doc "Active (non-revoked) tokens for a subject, newest activity first."
  @spec list_for_subject(String.t()) :: [OrchestratorToken.t()]
  def list_for_subject(subject_id) when is_binary(subject_id) do
    OrchestratorToken
    |> where([t], t.subject_id == ^subject_id and is_nil(t.revoked_at))
    |> order_by([t], desc: t.last_seen_at, desc: t.inserted_at)
    |> Repo.all()
  end

  def list_for_subject(_), do: []

  @doc """
  Revoke a token by id, but only if it belongs to `user` (subject match). Returns
  `{:ok, record}` or `{:error, :not_found}` — never reveals another subject's token.
  """
  @spec revoke(String.t(), map()) :: {:ok, OrchestratorToken.t()} | {:error, atom()}
  def revoke(id, user) when is_binary(id) and is_map(user) do
    case Repo.get_by(OrchestratorToken, id: id, subject_id: subject_id(user)) do
      nil ->
        {:error, :not_found}

      %OrchestratorToken{revoked_at: nil} = record ->
        record
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update()

      %OrchestratorToken{} = record ->
        {:ok, record}
    end
  end

  @doc "Stable subject id for a cockpit user map (matches minting + listing)."
  @spec subject_id(map()) :: String.t()
  def subject_id(user) when is_map(user) do
    to_string(user[:id] || user["id"] || user[:username] || user["username"])
  end

  @doc false
  def ttl_seconds do
    Application.get_env(:dev_ide, :orchestrator_token_ttl_seconds, @default_ttl_seconds)
  end

  @doc false
  def token_hash(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.url_encode64(padding: false)
  end

  defp generate_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp fetch(hash), do: Repo.get_by(OrchestratorToken, token_hash: hash)

  defp verify_record(nil, _now), do: {:error, :invalid_token}

  defp verify_record(%OrchestratorToken{revoked_at: revoked_at}, _now)
       when not is_nil(revoked_at),
       do: {:error, :revoked}

  defp verify_record(%OrchestratorToken{} = record, now) do
    if expired?(record, now) do
      {:error, :expired}
    else
      _ =
        record
        |> Ecto.Changeset.change(last_seen_at: now)
        |> Repo.update()

      {:ok,
       %{
         subject_id: record.subject_id,
         subject_email: record.subject_email,
         subject_role: record.subject_role
       }}
    end
  end

  defp expired?(%OrchestratorToken{expires_at: nil}, _now), do: false

  defp expired?(%OrchestratorToken{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  defp role_to_string(nil), do: "user"
  defp role_to_string(role) when is_atom(role), do: Atom.to_string(role)
  defp role_to_string(role) when is_binary(role), do: role

  defp normalize_label(nil), do: nil

  defp normalize_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 120)
    end
  end

  defp normalize_label(_), do: nil
end
