defmodule Casein.Mobile.TerminalChildGrants do
  @moduledoc "Digest-only issue, one-time begin-use, refresh, and revocation."

  import Ecto.Query

  alias Casein.Mobile.{TerminalChildGrant, TerminalSession}
  alias Casein.{Audit, Repo}

  @ttl_seconds 120
  @raw_bytes 32

  def issue(lease, topology_generation, opts \\ [])

  def issue(%TerminalSession{state: "active"} = lease, topology_generation, opts)
      when is_binary(topology_generation) and topology_generation != "" do
    raw = :crypto.strong_rand_bytes(@raw_bytes) |> Base.url_encode64(padding: false)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    expires_at = DateTime.add(now, Keyword.get(opts, :ttl_seconds, @ttl_seconds), :second)

    attrs = %{
      token_hash: digest(raw),
      user_id: lease.user_id,
      device_link_id: lease.device_link_id,
      origin_id: lease.origin_id,
      origin_generation: lease.origin_generation,
      workspace_id: lease.workspace_id,
      lease_id: lease.id,
      lifecycle_generation: lease.lifecycle_generation,
      sid: lease.sid,
      tmux_session: lease.tmux_session,
      pane_id: lease.pane_id,
      pane_role: lease.pane_role,
      topology_generation: topology_generation,
      mode: "read",
      expires_at: expires_at
    }

    with {:ok, grant} <-
           %TerminalChildGrant{} |> TerminalChildGrant.changeset(attrs) |> Repo.insert() do
      audit(grant, "mobile.terminal_grant_issued")
      {:ok, %{token: raw, grant: grant, expires_at: expires_at}}
    end
  end

  def issue(_lease, _topology_generation, _opts), do: {:error, :stale_lease}

  def refresh(%TerminalSession{} = lease, topology_generation, opts \\ []) do
    with_lease_lock(lease.id, fn ->
      revoke_active_for_lease(lease.id, Keyword.get(opts, :now, DateTime.utc_now()))

      case issue(lease, topology_generation, opts) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def begin_use(raw, context, connection_generation, opts \\ [])

  def begin_use(raw, context, connection_generation, opts)
      when is_binary(raw) and is_map(context) and is_binary(connection_generation) and
             connection_generation != "" do
    with_token_lock(digest(raw), fn ->
      grant = Repo.one(grant_query(digest(raw)))
      now = Keyword.get(opts, :now, DateTime.utc_now())

      with :ok <- validate(grant, context, now),
           nil <- grant.begun_at do
        grant
        |> TerminalChildGrant.changeset(%{
          begun_at: now,
          connection_generation: connection_generation
        })
        |> Repo.update()
        |> tap(fn
          {:ok, begun} -> audit(begun, "mobile.terminal_grant_begun")
          _other -> :ok
        end)
      else
        %DateTime{} -> {:error, :grant_already_used}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> flatten_transaction()
  end

  def begin_use(_raw, _context, _connection_generation, _opts),
    do: {:error, :invalid_payload}

  def authorize(%TerminalChildGrant{} = grant, context, connection_generation, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    current = Repo.get(TerminalChildGrant, grant.id)

    with :ok <- validate(current, context, now),
         true <- current.connection_generation == connection_generation do
      :ok
    else
      false -> {:error, :connection_generation_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke_for_lease(lease_id, opts \\ []) when is_binary(lease_id) do
    revoke_active_for_lease(lease_id, Keyword.get(opts, :now, DateTime.utc_now()))
  end

  defp validate(nil, _context, _now), do: {:error, :stale_grant}

  defp validate(grant, context, now) do
    cond do
      not is_nil(grant.revoked_at) -> {:error, :grant_revoked}
      DateTime.compare(grant.expires_at, now) != :gt -> {:error, :grant_expired}
      grant.mode != "read" -> {:error, :stale_grant}
      not context_matches?(grant, context) -> {:error, :stale_grant}
      true -> :ok
    end
  end

  defp context_matches?(grant, context) do
    fixed_match? =
      Enum.all?(
        [
          user_id: grant.user_id,
          device_link_id: grant.device_link_id,
          origin_id: grant.origin_id,
          origin_generation: grant.origin_generation,
          workspace_id: grant.workspace_id,
          lease_id: grant.lease_id,
          lifecycle_generation: grant.lifecycle_generation,
          sid: grant.sid,
          tmux_session: grant.tmux_session,
          pane_id: grant.pane_id,
          pane_role: grant.pane_role
        ],
        fn {key, expected} -> Map.get(context, key) == expected end
      )

    topology = Map.get(context, :topology_generation, grant.topology_generation)
    fixed_match? and topology == grant.topology_generation
  end

  defp revoke_active_for_lease(lease_id, now) do
    TerminalChildGrant
    |> where([g], g.lease_id == ^lease_id and is_nil(g.revoked_at))
    |> Repo.update_all(set: [revoked_at: now])
    |> elem(0)
  end

  defp grant_query(hash) do
    query = from g in TerminalChildGrant, where: g.token_hash == ^hash

    case repo_kind() do
      :postgres -> from g in query, lock: "FOR UPDATE"
      :sqlite -> query
      :unsupported -> raise "unsupported repository adapter"
    end
  end

  defp with_token_lock(hash, fun) do
    transaction = fn -> Repo.transaction(fun) end

    case repo_kind() do
      :postgres -> transaction.()
      :sqlite -> :global.trans({{__MODULE__, hash}, self()}, transaction)
      :unsupported -> {:error, :unsupported_repo_adapter}
    end
  end

  defp with_lease_lock(lease_id, fun) do
    transaction = fn ->
      Repo.transaction(fn ->
        if repo_kind() == :postgres do
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lease_id])
        end

        fun.()
      end)
    end

    case repo_kind() do
      :postgres -> transaction.()
      :sqlite -> :global.trans({{__MODULE__, {:lease, lease_id}}, self()}, transaction)
      :unsupported -> {:error, :unsupported_repo_adapter}
    end
  end

  defp flatten_transaction({:ok, {:ok, grant}}), do: {:ok, grant}
  defp flatten_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp flatten_transaction({:error, reason}), do: {:error, reason}

  defp repo_kind do
    case apply(Repo, :__adapter__, []) do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.SQLite3 -> :sqlite
      _other -> :unsupported
    end
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp audit(grant, action) do
    Audit.emit!(%{
      action: action,
      workspace_id: grant.workspace_id,
      actor_id: grant.user_id,
      target_type: "mobile_terminal",
      target_ref: grant.lease_id,
      metadata: %{
        lease_id: grant.lease_id,
        origin_id: grant.origin_id,
        device_link_id: grant.device_link_id,
        lifecycle_generation: grant.lifecycle_generation,
        mode: grant.mode
      }
    })
  end
end
