defmodule Casein.Mobile.TerminalSessions do
  @moduledoc "Authoritative lifecycle for server-owned disposable mobile terminals."

  import Ecto.Query

  alias Casein.Mobile.TerminalSession
  alias Casein.Terminals.ScrollbackArchive
  alias Casein.{Audit, Repo, Terminals}

  @default_ttl_seconds 3_600
  @active_states ~w(provisioning active deleting expired failed)

  @type create_attrs :: %{
          required(:user_id) => String.t(),
          required(:device_link_id) => String.t(),
          required(:origin_id) => String.t(),
          required(:origin_generation) => String.t(),
          required(:workspace_id) => String.t(),
          required(:workspace_key) => String.t(),
          required(:workspace_root) => String.t(),
          required(:request_id) => Ecto.UUID.t()
        }

  @spec create(create_attrs(), keyword()) :: {:ok, TerminalSession.t()} | {:error, term()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, normalized} <- validate_create_attrs(attrs),
         {:ok, ttl} <- validate_ttl(Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      fingerprint = fingerprint(normalized)
      lease_id = Ecto.UUID.generate()
      sid = "mob-" <> Ecto.UUID.generate()

      create_attrs =
        Map.merge(normalized, %{
          id: lease_id,
          sid: sid,
          tmux_session: Terminals.tmux_session_name(normalized.workspace_key, sid),
          request_fingerprint: fingerprint,
          lifecycle_generation: Ecto.UUID.generate(),
          pane_role: TerminalSession.role(),
          state: "provisioning",
          expires_at: DateTime.add(now, ttl, :second)
        })

      case Repo.insert(TerminalSession.create_changeset(%TerminalSession{}, create_attrs)) do
        {:ok, lease} -> provision(lease, opts)
        {:error, changeset} -> resolve_create_conflict(changeset, create_attrs, opts)
      end
    end
  end

  def get(id) when is_binary(id), do: Repo.get(TerminalSession, id)

  def owns_tmux_session?(tmux_session) when is_binary(tmux_session) do
    Repo.exists?(from s in TerminalSession, where: s.tmux_session == ^tmux_session)
  end

  @spec delete(TerminalSession.t() | String.t(), keyword()) ::
          {:ok, TerminalSession.t()} | {:error, term()}
  def delete(session_or_id, opts \\ []) do
    id = if match?(%TerminalSession{}, session_or_id), do: session_or_id.id, else: session_or_id

    with {:ok, lease} <- claim_deleting(id),
         {:ok, result} <- with_lease_lock(id, fn -> teardown_locked(lease, opts) end) do
      result
    end
  end

  @doc "Retry unfinished/expired leases. Intended for the supervised reaper."
  def reconcile_due(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    TerminalSession
    |> where([s], s.state in ^@active_states)
    |> where([s], s.expires_at <= ^now or s.state in ["deleting", "expired", "failed"])
    |> order_by([s], asc: s.expires_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
    |> Enum.map(fn lease -> delete(lease.id, Keyword.put(opts, :expired?, true)) end)
  end

  @doc "Reconcile provisioning leases after a release restart."
  def reconcile_startup(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    TerminalSession
    |> where([s], s.state == "provisioning" and s.expires_at > ^now)
    |> Repo.all()
    |> Enum.map(&provision(&1, opts))
  end

  defp provision(%TerminalSession{id: id}, opts) do
    case with_lease_lock(id, fn -> provision_locked(id, opts) end) do
      {:ok, {:created, active}} ->
        audit(active, "mobile.terminal_created")
        {:ok, active}

      {:ok, {:existing, active}} ->
        {:ok, active}

      {:ok, {:retry, reason}} ->
        {:error, reason}

      {:ok, {:fatal, failed, reason}} ->
        audit(failed, "mobile.terminal_rejected", bounded_reason(reason))
        _ = delete(failed.id, opts)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provision_locked(id, opts) do
    lease = Repo.get!(TerminalSession, id)

    case lease.state do
      "active" -> {:existing, lease}
      "provisioning" -> provision_tmux(lease, opts)
      other -> {:retry, {:invalid_state, other}}
    end
  end

  defp provision_tmux(lease, opts) do
    tmux = adapter(opts)

    result =
      with :ok <- ScrollbackArchive.delete(lease.tmux_session),
           :ok <- tmux.ensure_session(lease.tmux_session, lease.workspace_root),
           [pane] <- tmux.list_session_panes(lease.tmux_session),
           pane_id when is_binary(pane_id) <- Map.get(pane, :id),
           :ok <- tmux.set_pane_role(lease.tmux_session, pane_id, lease.pane_role) do
        activate(lease, pane_id)
      else
        [] -> {:error, :missing_initial_pane}
        panes when is_list(panes) -> {:error, :unexpected_topology}
        nil -> {:error, :missing_pane_id}
        {:error, _} = error -> error
        other -> {:error, {:provision_failed, other}}
      end

    case result do
      {:ok, active} ->
        {:created, active}

      {:error, reason} ->
        if reason in [:missing_initial_pane, :unexpected_topology, :missing_pane_id] do
          {:fatal, mark_failed(lease, reason), reason}
        else
          record_retryable_provision_failure(lease, reason)
          {:retry, reason}
        end
    end
  end

  defp activate(lease, pane_id) do
    lease
    |> TerminalSession.transition_changeset(%{state: "active", pane_id: pane_id})
    |> Repo.update()
  end

  defp mark_failed(lease, reason) do
    code = bounded_reason(reason)

    {:ok, failed} =
      lease
      |> TerminalSession.transition_changeset(%{state: "failed", failure_code: code})
      |> Repo.update()

    failed
  end

  defp record_retryable_provision_failure(lease, reason) do
    code = bounded_reason(reason)

    lease
    |> TerminalSession.transition_changeset(%{
      state: "provisioning",
      failure_code: code
    })
    |> Repo.update!()
  end

  defp claim_deleting(id) when is_binary(id) do
    case Repo.transaction(fn ->
           query = from s in TerminalSession, where: s.id == ^id, lock: "FOR UPDATE"

           case Repo.one(query) do
             nil ->
               Repo.rollback(:not_found)

             %TerminalSession{state: "deleted"} = lease ->
               lease

             %TerminalSession{state: "deleting"} = lease ->
               lease

             lease ->
               lease
               |> TerminalSession.transition_changeset(%{state: "deleting"})
               |> Repo.update!()
           end
         end) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, reason}
    end
  end

  defp teardown_locked(claimed_lease, opts) do
    lease = Repo.get!(TerminalSession, claimed_lease.id)

    if lease.state == "deleted" do
      {:ok, lease}
    else
      teardown(lease, opts)
    end
  end

  defp teardown(lease, opts) do
    tmux = adapter(opts)

    with :ok <- verify_identity(lease),
         :ok <- Terminals.stop_shell_owner(lease.workspace_id, lease.sid),
         :ok <- Terminals.stop_session_exact(lease.workspace_key, lease.sid),
         :ok <- normalize_kill(tmux.kill(lease.tmux_session)),
         false <- tmux.session_exists?(lease.tmux_session) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      {:ok, deleted} =
        lease
        |> TerminalSession.transition_changeset(%{state: "deleted", ended_at: now})
        |> Repo.update()

      audit(
        deleted,
        if(Keyword.get(opts, :expired?, false),
          do: "mobile.terminal_expired",
          else: "mobile.terminal_deleted"
        )
      )

      {:ok, deleted}
    else
      true -> {:error, :tmux_still_present}
      {:error, _} = error -> error
    end
  end

  defp verify_identity(lease) do
    expected = Terminals.tmux_session_name(lease.workspace_key, lease.sid)
    if expected == lease.tmux_session, do: :ok, else: {:error, :identity_mismatch}
  end

  defp normalize_kill(:ok), do: :ok
  defp normalize_kill({:error, reason}) when reason in [:not_found, :no_session], do: :ok
  defp normalize_kill({:error, {1, _}}), do: :ok
  defp normalize_kill(other), do: other

  defp with_lease_lock(id, fun) when is_binary(id) and is_function(fun, 0) do
    case Repo.transaction(fn ->
           Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [id])
           fun.()
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_create_conflict(changeset, attrs, opts) do
    if changeset.errors[:request_id] || changeset.errors[:device_link_id] do
      existing =
        Repo.get_by!(TerminalSession,
          device_link_id: attrs.device_link_id,
          request_id: attrs.request_id
        )

      if existing.request_fingerprint == attrs.request_fingerprint do
        provision(existing, opts)
      else
        {:error, :idempotency_key_reused}
      end
    else
      {:error, changeset}
    end
  end

  defp adapter(opts), do: Keyword.get(opts, :tmux, Terminals.tmux_adapter())

  defp fingerprint(attrs) do
    attrs
    |> atomize_required()
    |> Map.take([:user_id, :device_link_id, :origin_id, :origin_generation, :workspace_id])
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp atomize_required(attrs) do
    Map.new(
      ~w(user_id device_link_id origin_id origin_generation workspace_id workspace_key workspace_root request_id)a,
      fn key -> {key, fetch(attrs, key)} end
    )
  end

  defp validate_create_attrs(attrs) do
    normalized = atomize_required(attrs)

    binaries =
      ~w(user_id device_link_id origin_id origin_generation workspace_id workspace_key workspace_root)a

    valid_binaries? = Enum.all?(binaries, &(is_binary(normalized[&1]) and normalized[&1] != ""))

    if valid_binaries? and Path.type(normalized.workspace_root) == :absolute and
         match?({:ok, _}, Ecto.UUID.cast(normalized.request_id)) do
      {:ok, normalized}
    else
      {:error, :invalid_create_attrs}
    end
  end

  defp validate_ttl(ttl) when is_integer(ttl) and ttl > 0 and ttl <= @default_ttl_seconds,
    do: {:ok, ttl}

  defp validate_ttl(_ttl), do: {:error, :invalid_ttl}

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp bounded_reason(reason) do
    reason
    |> inspect(limit: 3, printable_limit: 40)
    |> String.slice(0, 80)
  end

  defp audit(lease, action, reason_code \\ nil) do
    Audit.emit!(%{
      action: action,
      workspace_id: lease.workspace_id,
      actor_id: lease.user_id,
      target_type: "mobile_terminal",
      target_ref: lease.id,
      metadata: %{
        terminal_id: lease.id,
        origin_id: lease.origin_id,
        device_link_id: lease.device_link_id,
        sid: lease.sid,
        tmux_session: lease.tmux_session,
        pane_id: lease.pane_id,
        state: lease.state,
        expires_at: lease.expires_at,
        reason_code: reason_code
      }
    })
  end
end
