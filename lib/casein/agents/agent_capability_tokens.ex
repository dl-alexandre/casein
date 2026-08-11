defmodule Casein.Agents.AgentCapabilityTokens do
  @moduledoc """
  Persistence and lifecycle for short-lived, session-bound agent capabilities.

  Raw bearer tokens are returned only when minted. The database stores a
  SHA-256 hash plus the frozen workspace, leader, bundle, mode, and exact tool
  claims needed to authorize a managed Grok session.
  """

  import Ecto.Query

  alias Casein.Agents.AgentCapabilityToken
  alias Casein.Repo

  @default_ttl_seconds 60 * 60 * 12
  @touch_interval_seconds 60
  @prune_batch_size 1_000
  @known_keys [
    :workspace_id,
    :runtime,
    :tmux_session_id,
    :pane_id,
    :leader_id,
    :bundle_digest,
    :workspace_mode,
    :allowed_tools,
    :checkout_digest
  ]

  @type claims :: %{
          id: Ecto.UUID.t(),
          workspace_id: String.t(),
          runtime: String.t(),
          tmux_session_id: String.t(),
          pane_id: String.t(),
          leader_id: String.t(),
          bundle_digest: String.t(),
          workspace_mode: String.t(),
          allowed_tools: %{String.t() => [String.t()]},
          checkout_digest: String.t() | nil,
          expires_at: DateTime.t()
        }

  @doc """
  Mint a managed Grok capability from trusted, server-derived claims.

  Returns `{:ok, raw_token, record}`. The raw value is never persisted and
  cannot be recovered from the returned record.
  """
  @spec create_for_grok(map()) ::
          {:ok, String.t(), AgentCapabilityToken.t()} | {:error, Ecto.Changeset.t()}
  def create_for_grok(attrs) when is_map(attrs) do
    raw_token = generate_token()
    now = DateTime.utc_now()
    _ = prune_stale(DateTime.add(now, -ttl_seconds(), :second))

    attrs =
      attrs
      |> stringify_known_keys()
      |> Map.put_new("runtime", "grok")
      |> Map.merge(%{
        "token_hash" => token_hash(raw_token),
        "expires_at" => DateTime.add(now, ttl_seconds(), :second)
      })

    changeset = AgentCapabilityToken.changeset(%AgentCapabilityToken{}, attrs)

    case Repo.transaction(fn ->
           revoke_replaced_binding(attrs, now)

           case Repo.insert(changeset) do
             {:ok, record} -> record
             {:error, changeset} -> Repo.rollback(changeset)
           end
         end) do
      {:ok, record} ->
        broadcast_binding_changed(record.workspace_id)
        {:ok, raw_token, record}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Whether any capability-scoped agent is currently bound to this workspace.

  "Bound" is a property of the *credential*, not of a pane: a live, unrevoked,
  unexpired bearer can call MCP whether or not the tmux pane that received it
  still exists. Chrome that reports the agent-write grant keys off this so a
  workspace running only ungated runtimes (Claude / Codex / OpenCode) does not
  advertise a control that binds nothing.

  The launcher never revokes on pane exit — it re-verifies and reuses a cached
  bearer — so a closed Grok pane keeps its workspace "bound" until the token
  hits its 12h TTL or the same leader mints a replacement. That tail is
  deliberate: the credential really is still usable during it.
  """
  @spec any_active_for_workspace?(String.t()) :: boolean()
  def any_active_for_workspace?(workspace_id) when is_binary(workspace_id) do
    now = DateTime.utc_now()

    AgentCapabilityToken
    |> where(
      [token],
      token.workspace_id == ^workspace_id and is_nil(token.revoked_at) and token.expires_at > ^now
    )
    |> Repo.exists?()
  end

  def any_active_for_workspace?(_workspace_id), do: false

  @doc """
  Subscribes the caller to capability binding changes for a workspace.

  Delivers `{:agent_capability_binding_changed, workspace_id}` after a mint or
  a revoke. Broadcasting lives here rather than in the controller for the same
  reason the unlock audit lives in `Casein.Workspaces.State`: a control whose
  chrome depends on the binding cannot rely on each caller remembering to say
  it changed. Passive expiry is not broadcast — nothing re-reads the table on a
  timer, so a subscriber can hold a stale `true` until the next mint, revoke,
  or remount.
  """
  @spec subscribe_binding_changes(String.t()) :: :ok | {:error, term()}
  def subscribe_binding_changes(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(Casein.PubSub, binding_topic(workspace_id))
  end

  defp broadcast_binding_changed(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.broadcast(
      Casein.PubSub,
      binding_topic(workspace_id),
      {:agent_capability_binding_changed, workspace_id}
    )
  end

  defp broadcast_binding_changed(_workspace_id), do: :ok

  defp binding_topic(workspace_id), do: "workspace_agent_capabilities:" <> workspace_id

  @doc """
  Verify an active raw bearer and return only authorization-safe claims.

  Successful verification opportunistically touches `last_seen_at` at most
  once per minute per token.
  """
  @spec verify(String.t()) :: {:ok, claims()} | {:error, atom()}
  def verify(raw_token) when is_binary(raw_token) do
    case String.trim(raw_token) do
      "" -> {:error, :missing}
      trimmed -> verify_hash(token_hash(trimmed), DateTime.utc_now())
    end
  end

  def verify(_raw_token), do: {:error, :missing}

  @doc "Revoke a capability by id, scoped to its owning workspace."
  @spec revoke(String.t(), String.t()) ::
          {:ok, AgentCapabilityToken.t()} | {:error, :not_found}
  def revoke(id, workspace_id) when is_binary(id) and is_binary(workspace_id) do
    with {:ok, id} <- cast_id(id) do
      AgentCapabilityToken
      |> Repo.get_by(id: id, workspace_id: workspace_id)
      |> revoke_record()
    else
      :error -> {:error, :not_found}
    end
  end

  def revoke(_id, _workspace_id), do: {:error, :not_found}

  @doc "Revoke the current capability after its id was established by verification."
  @spec revoke_current(String.t()) ::
          {:ok, AgentCapabilityToken.t()} | {:error, :not_found}
  def revoke_current(id) when is_binary(id) do
    with {:ok, id} <- cast_id(id) do
      AgentCapabilityToken
      |> Repo.get(id)
      |> revoke_record()
    else
      :error -> {:error, :not_found}
    end
  end

  def revoke_current(_id), do: {:error, :not_found}

  @doc false
  def ttl_seconds do
    case Application.get_env(
           :casein,
           :grok_agent_capability_token_ttl_seconds,
           @default_ttl_seconds
         ) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _invalid -> @default_ttl_seconds
    end
  end

  @doc false
  def token_hash(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.url_encode64(padding: false)
  end

  defp generate_token do
    "grokcap_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @doc "Delete a bounded batch of expired or revoked capability records."
  @spec prune_stale(DateTime.t()) :: non_neg_integer()
  def prune_stale(now \\ DateTime.utc_now()) do
    ids =
      AgentCapabilityToken
      |> where(
        [token],
        token.expires_at <= ^now or (not is_nil(token.revoked_at) and token.revoked_at <= ^now)
      )
      |> order_by([token], asc: token.expires_at)
      |> limit(@prune_batch_size)
      |> select([token], token.id)

    {count, _} =
      AgentCapabilityToken
      |> where([token], token.id in subquery(ids))
      |> Repo.delete_all()

    count
  end

  defp verify_hash(hash, now) do
    case Repo.transaction(fn ->
           AgentCapabilityToken
           |> where([token], token.token_hash == ^hash)
           |> lock("FOR UPDATE")
           |> Repo.one()
           |> verify_record(now)
         end) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :verification_failed}
    end
  end

  defp verify_record(nil, _now), do: {:error, :invalid_token}

  defp verify_record(%AgentCapabilityToken{revoked_at: revoked_at}, _now)
       when not is_nil(revoked_at),
       do: {:error, :revoked}

  defp verify_record(%AgentCapabilityToken{} = record, now) do
    if expired?(record, now) do
      {:error, :expired}
    else
      maybe_touch_last_seen(record, now)
      {:ok, claims(record)}
    end
  end

  defp claims(record) do
    %{
      id: record.id,
      workspace_id: record.workspace_id,
      runtime: record.runtime,
      tmux_session_id: record.tmux_session_id,
      pane_id: record.pane_id,
      leader_id: record.leader_id,
      bundle_digest: record.bundle_digest,
      workspace_mode: record.workspace_mode,
      allowed_tools: record.allowed_tools,
      checkout_digest: record.checkout_digest,
      expires_at: record.expires_at
    }
  end

  defp maybe_touch_last_seen(%AgentCapabilityToken{} = record, now) do
    if touch_due?(record.last_seen_at, now) do
      AgentCapabilityToken
      |> where([token], token.id == ^record.id and is_nil(token.revoked_at))
      |> Repo.update_all(set: [last_seen_at: now])
    end

    :ok
  end

  defp touch_due?(nil, _now), do: true

  defp touch_due?(last_seen_at, now),
    do: DateTime.diff(now, last_seen_at, :second) >= @touch_interval_seconds

  defp expired?(%AgentCapabilityToken{expires_at: nil}, _now), do: true

  defp expired?(%AgentCapabilityToken{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  defp revoke_record(nil), do: {:error, :not_found}

  defp revoke_record(%AgentCapabilityToken{revoked_at: nil} = record) do
    case record |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update() do
      {:ok, updated} = ok ->
        broadcast_binding_changed(updated.workspace_id)
        ok

      other ->
        other
    end
  end

  defp revoke_record(%AgentCapabilityToken{} = record), do: {:ok, record}

  defp revoke_replaced_binding(attrs, now) do
    AgentCapabilityToken
    |> where(
      [token],
      token.runtime == "grok" and
        token.workspace_id == ^attrs["workspace_id"] and
        token.leader_id == ^attrs["leader_id"] and
        is_nil(token.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  defp stringify_known_keys(attrs) do
    Enum.reduce(@known_keys, %{}, fn key, acc ->
      string_key = Atom.to_string(key)

      case Map.fetch(attrs, key) do
        {:ok, value} ->
          Map.put(acc, string_key, value)

        :error ->
          case Map.fetch(attrs, string_key) do
            {:ok, value} -> Map.put(acc, string_key, value)
            :error -> acc
          end
      end
    end)
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, cast} -> {:ok, cast}
      :error -> :error
    end
  end
end
