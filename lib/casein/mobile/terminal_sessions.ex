defmodule Casein.Mobile.TerminalSessions do
  @moduledoc "Authoritative lifecycle for server-owned disposable mobile terminals."

  import Ecto.Query

  alias Casein.Mobile.{TerminalChildGrants, TerminalSession, TerminalStream}
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

  @doc """
  Deletes an active lease, or reconciles a replay when that exact scoped lease
  is already durably deleted.

  Scope mismatches deliberately collapse to `:not_found` so a caller cannot use
  retained deleted rows to enumerate another device's terminal history.
  """
  @spec delete_authorized(String.t(), map(), keyword()) ::
          {:ok, TerminalSession.t()} | {:error, term()}
  def delete_authorized(id, context, opts \\ []) when is_binary(id) and is_map(context) do
    case Repo.get(TerminalSession, id) do
      nil ->
        {:error, :not_found}

      %TerminalSession{} = lease ->
        with :ok <- validate_delete_context(lease, context) do
          if lease.state == "deleted" do
            {:ok, lease}
          else
            with {:ok, _authorized} <- authorize_read(id, context, opts),
                 do: delete(id, opts)
          end
        end
    end
  end

  @doc "Revalidates an active lease against durable scope and live tmux identity/topology."
  def authorize_read(id, context, opts \\ []) when is_binary(id) and is_map(context) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    tmux = adapter(opts)

    with %TerminalSession{} = lease <- Repo.get(TerminalSession, id),
         :ok <- validate_read_context(lease, context, now),
         :ok <- verify_identity(lease),
         {:ok, identity} <- tmux.mobile_terminal_identity(lease.tmux_session),
         true <- identity == %{session_id: lease.tmux_native_id, marker: lease.tmux_lease_marker},
         {:ok, :present} <- verify_live_topology(lease, tmux) do
      {:ok, lease}
    else
      nil -> {:error, :not_found}
      false -> {:error, :identity_mismatch}
      {:ok, :absent} -> {:error, :stale_lease}
      {:error, reason} -> {:error, reason}
    end
  end

  # Served by mobile_terminal_sessions(workspace_id, sid). Do not drop that
  # index: workspace_id is trailing in every other index, so this lease-auth
  # path sequential-scans lease history without it (#926).
  def lease_owned_sid?(workspace_id, sid) when is_binary(workspace_id) and is_binary(sid) do
    Repo.exists?(
      from s in TerminalSession,
        where: s.workspace_id == ^workspace_id and s.sid == ^sid and s.state != "deleted"
    )
  end

  def reserved_sid?(sid) when is_binary(sid),
    do: Regex.match?(~r/\Amob-[0-9a-f-]{36}\z/, sid)

  @doc "Start/reuse the PTY only for an authoritative active mobile lease."
  def ensure_pty(session_or_id, opts \\ []) do
    id = if match?(%TerminalSession{}, session_or_id), do: session_or_id.id, else: session_or_id
    session_module = Keyword.get(opts, :session_module, Casein.Terminals.Session)

    case Repo.get(TerminalSession, id) do
      %TerminalSession{state: "active"} = lease ->
        session_module.ensure_started(
          lease.workspace_key,
          lease.sid,
          {:local, lease.workspace_root},
          archive: :ephemeral
        )

      %TerminalSession{} ->
        {:error, :terminal_not_active}

      nil ->
        {:error, :not_found}
    end
  end

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
    |> Enum.map(fn lease ->
      expired? = lease.state == "expired" or DateTime.compare(lease.expires_at, now) != :gt
      delete(lease.id, Keyword.put(opts, :expired?, expired?))
    end)
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
        {:error, public_reason(reason)}

      {:ok, {:fatal, failed, reason}} ->
        audit(failed, "mobile.terminal_rejected", failure_code(reason))
        _ = delete(failed.id, opts)
        {:error, public_reason(reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provision_locked(id, opts) do
    lease = Repo.one!(lease_query(id))

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
           {:ok, identity} <-
             tmux.set_mobile_terminal_identity(
               lease.tmux_session,
               lease.lifecycle_generation
             ),
           {:ok, identified_lease} <- persist_tmux_identity(lease, identity),
           [pane] <- tmux.list_session_panes(lease.tmux_session),
           pane_id when is_binary(pane_id) <- Map.get(pane, :id),
           :ok <- tmux.set_pane_role(lease.tmux_session, pane_id, lease.pane_role) do
        activate(identified_lease, pane_id)
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

  defp persist_tmux_identity(lease, %{session_id: native_id, marker: marker})
       when is_binary(native_id) and native_id != "" and is_binary(marker) and marker != "" do
    lease
    |> TerminalSession.transition_changeset(%{
      state: "provisioning",
      tmux_native_id: native_id,
      tmux_lease_marker: marker
    })
    |> Repo.update()
  end

  defp persist_tmux_identity(_lease, _identity), do: {:error, :invalid_tmux_identity}

  defp activate(lease, pane_id) do
    lease
    |> TerminalSession.transition_changeset(%{state: "active", pane_id: pane_id})
    |> Repo.update()
  end

  defp mark_failed(lease, reason) do
    code = failure_code(reason)

    {:ok, failed} =
      lease
      |> TerminalSession.transition_changeset(%{state: "failed", failure_code: code})
      |> Repo.update()

    failed
  end

  defp record_retryable_provision_failure(lease, reason) do
    code = failure_code(reason)

    lease
    |> TerminalSession.transition_changeset(%{
      state: "provisioning",
      failure_code: code
    })
    |> Repo.update!()
  end

  defp claim_deleting(id) when is_binary(id) do
    with_lease_lock(id, fn -> claim_deleting_locked(id) end)
  end

  defp claim_deleting_locked(id) do
    case Repo.one(lease_query(id)) do
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
  end

  defp teardown_locked(claimed_lease, opts) do
    lease = Repo.get!(TerminalSession, claimed_lease.id)

    if lease.state == "deleted" do
      {:ok, lease}
    else
      with :ok <- run_before_teardown(lease, opts) do
        teardown(lease, opts)
      end
    end
  end

  defp run_before_teardown(lease, opts) do
    _ = TerminalChildGrants.revoke_for_lease(lease.id)

    with :ok <- TerminalStream.cutoff_lease(lease.id, "stale_lease") do
      case Keyword.get(opts, :before_teardown) do
        nil -> :ok
        callback when is_function(callback, 1) -> callback.(lease)
      end
    end
  end

  defp teardown(lease, opts) do
    if is_nil(lease.pane_id) do
      teardown_never_active(lease, opts)
    else
      teardown_active(lease, opts)
    end
  end

  # A provisioning lease can fail before a trustworthy pane identity exists
  # (empty/multiple panes or a pane without an id). Requiring the missing pane
  # identity here would make the server-owned tmux session unreapable. The
  # durable lease is still authoritative for the exact derived session name,
  # so clean up only that name and never enumerate or derive a prefix target.
  defp teardown_never_active(lease, opts) do
    tmux = adapter(opts)
    terminal_control = Keyword.get(opts, :terminal_control, Terminals)

    with :ok <- verify_lease_name(lease),
         :ok <- terminal_control.stop_shell_owner(lease.workspace_id, lease.sid),
         :ok <- terminal_control.stop_session_exact(lease.workspace_key, lease.sid) do
      if tmux.session_exists?(lease.tmux_session) do
        with :ok <- verify_identity(lease),
             :ok <- maybe_kill_exact_tmux(tmux, lease),
             false <- tmux.session_exists?(lease.tmux_session) do
          complete_delete(lease, opts)
        else
          true -> {:error, :tmux_still_present}
          {:error, _} = error -> error
        end
      else
        complete_delete(lease, opts)
      end
    else
      {:error, _} = error -> error
    end
  end

  defp teardown_active(lease, opts) do
    tmux = adapter(opts)
    terminal_control = Keyword.get(opts, :terminal_control, Terminals)

    with :ok <- verify_identity(lease),
         {:ok, initial_topology} <- verify_live_topology(lease, tmux),
         :ok <- terminal_control.stop_shell_owner(lease.workspace_id, lease.sid),
         :ok <- terminal_control.stop_session_exact(lease.workspace_key, lease.sid),
         {:ok, final_topology} <- verify_live_topology(lease, tmux),
         {:ok, topology_state} <- reconcile_topology(initial_topology, final_topology),
         :ok <- maybe_kill_tmux(tmux, lease, topology_state),
         false <- tmux.session_exists?(lease.tmux_session) do
      complete_delete(lease, opts)
    else
      true -> {:error, :tmux_still_present}
      {:error, _} = error -> error
    end
  end

  defp complete_delete(lease, opts) do
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
  end

  defp verify_identity(lease) do
    with :ok <- verify_lease_name(lease) do
      cond do
        not is_binary(lease.tmux_native_id) -> {:error, :tmux_identity_missing}
        not is_binary(lease.tmux_lease_marker) -> {:error, :tmux_identity_missing}
        lease.tmux_lease_marker != lease.lifecycle_generation -> {:error, :identity_mismatch}
        true -> :ok
      end
    end
  end

  defp validate_read_context(lease, context, now) do
    expected = [
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
      pane_role: lease.pane_role
    ]

    cond do
      lease.state != "active" ->
        {:error, :stale_lease}

      DateTime.compare(lease.expires_at, now) != :gt ->
        {:error, :stale_lease}

      Enum.any?(expected, fn {key, value} -> Map.get(context, key) != value end) ->
        {:error, :identity_mismatch}

      true ->
        :ok
    end
  end

  defp validate_delete_context(lease, context) do
    expected = [
      user_id: lease.user_id,
      device_link_id: lease.device_link_id,
      origin_id: lease.origin_id,
      origin_generation: lease.origin_generation,
      workspace_id: lease.workspace_id,
      lease_id: lease.id
    ]

    if Enum.all?(expected, fn {key, value} -> Map.get(context, key) == value end),
      do: :ok,
      else: {:error, :not_found}
  end

  defp verify_lease_name(lease) do
    expected = Terminals.tmux_session_name(lease.workspace_key, lease.sid)
    if expected == lease.tmux_session, do: :ok, else: {:error, :identity_mismatch}
  end

  defp verify_live_topology(lease, tmux) do
    if tmux.session_exists?(lease.tmux_session) do
      case tmux.list_session_panes(lease.tmux_session) do
        [pane] ->
          cond do
            Map.get(pane, :id) != lease.pane_id -> {:error, :pane_identity_mismatch}
            Map.get(pane, :role) != lease.pane_role -> {:error, :pane_role_mismatch}
            true -> {:ok, :present}
          end

        [] ->
          if tmux.session_exists?(lease.tmux_session) do
            {:error, :missing_terminal_pane}
          else
            {:ok, :absent}
          end

        _panes ->
          {:error, :unexpected_topology}
      end
    else
      {:ok, :absent}
    end
  end

  defp reconcile_topology(:present, :present), do: {:ok, :present}
  defp reconcile_topology(:present, :absent), do: {:ok, :absent}
  defp reconcile_topology(:absent, :absent), do: {:ok, :absent}
  defp reconcile_topology(:absent, :present), do: {:error, :terminal_session_reappeared}

  defp maybe_kill_tmux(tmux, lease, :present),
    do:
      normalize_kill(
        tmux.kill_mobile_terminal(
          lease.tmux_session,
          lease.tmux_native_id,
          lease.tmux_lease_marker
        )
      )

  defp maybe_kill_tmux(_tmux, _lease, :absent), do: :ok

  defp maybe_kill_exact_tmux(tmux, lease) do
    if tmux.session_exists?(lease.tmux_session) do
      normalize_kill(
        tmux.kill_mobile_terminal(
          lease.tmux_session,
          lease.tmux_native_id,
          lease.tmux_lease_marker
        )
      )
    else
      :ok
    end
  end

  defp normalize_kill(:ok), do: :ok
  defp normalize_kill({:error, reason}) when reason in [:not_found, :no_session], do: :ok
  defp normalize_kill({:error, {1, _}}), do: :ok

  defp normalize_kill({:error, reason})
       when reason in [
              :temporarily_unavailable,
              :mobile_terminal_identity_mismatch,
              :invalid_mobile_terminal_identity
            ],
       do: {:error, reason}

  # Adapter failures may include tmux output. Teardown and the supervised
  # reaper expose only a fixed code; raw subprocess values never cross this
  # boundary into callers, logs, or audit metadata.
  defp normalize_kill(_other), do: {:error, :tmux_teardown_failed}

  defp with_lease_lock(id, fun) when is_binary(id) and is_function(fun, 0) do
    transaction = fn ->
      Repo.transaction(fn ->
        case repo_kind() do
          :postgres ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [id])

          :sqlite ->
            :ok
        end

        fun.()
      end)
    end

    result =
      case repo_kind() do
        :postgres ->
          transaction.()

        :sqlite ->
          # Desktop SQLite is single-node. A keyed in-node lock supplies the
          # same exact-lease serialization without issuing Postgres-only SQL.
          :global.trans({{__MODULE__, id}, self()}, transaction)

        :unsupported ->
          {:error, :unsupported_repo_adapter}
      end

    case result do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lease_query(id) do
    query = from s in TerminalSession, where: s.id == ^id

    case repo_kind() do
      :postgres -> from s in query, lock: "FOR UPDATE"
      :sqlite -> query
      :unsupported -> raise "unsupported repository adapter"
    end
  end

  defp repo_kind do
    # Resolve from the compiled Repo itself. `apply/3` keeps multi-adapter
    # release builds warning-clean while avoiding mutable application env.
    case apply(Repo, :__adapter__, []) do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.SQLite3 -> :sqlite
      _other -> :unsupported
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
    |> Map.take([
      :user_id,
      :device_link_id,
      :origin_id,
      :origin_generation,
      :workspace_id,
      :workspace_key,
      :workspace_root
    ])
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

  # Persist only a small typed allowlist. Adapter/subprocess failures may carry
  # inspected command output, paths, or terminal bytes and must never reach the
  # durable lease or audit metadata.
  defp failure_code(:missing_initial_pane), do: "missing_initial_pane"
  defp failure_code(:unexpected_topology), do: "unexpected_topology"
  defp failure_code(:missing_pane_id), do: "missing_pane_id"
  defp failure_code(:temporarily_unavailable), do: "tmux_temporarily_unavailable"
  defp failure_code(_reason), do: "tmux_provision_failed"

  defp public_reason(:missing_initial_pane), do: :missing_initial_pane
  defp public_reason(:unexpected_topology), do: :unexpected_topology
  defp public_reason(:missing_pane_id), do: :missing_pane_id
  defp public_reason(:temporarily_unavailable), do: :temporarily_unavailable
  defp public_reason(_reason), do: :tmux_provision_failed

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
        pane_id: lease.pane_id,
        state: lease.state,
        expires_at: lease.expires_at,
        reason_code: reason_code
      }
    })
  end
end
