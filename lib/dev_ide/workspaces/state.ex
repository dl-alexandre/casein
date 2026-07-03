defmodule DevIDE.Workspaces.State do
  @moduledoc """
  Persistence boundary for workspace records.

  Public API maps `DevIDE.Workspace` and `DevIDE.Workspaces.DbIsolation`
  into `WorkspaceRecord` upserts. Adapters do the storage. Only
  **redacted** fields are persisted — see `sanitize_manager_payload/1`
  for the deny list.

  Resolution helper `mode_for/1` answers "what mode applies to this
  workspace?" with explicit precedence: config override > persisted >
  default.
  """

  alias DevIDE.Workspaces.State.WorkspaceRecord
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspace
  alias DevIDE.Policy.WorkspaceMode

  ## Public API

  @doc "Upsert a workspace from its source (sync hook)."
  @spec sync(Workspace.t() | map()) :: {:ok, WorkspaceRecord.t()} | {:error, term()}
  def sync(%Workspace{} = ws) do
    impl().upsert(merge_existing(build_record(ws)))
  end

  def sync(other), do: {:error, {:not_a_workspace, other}}

  @doc """
  Batched form of `sync/1` for a list of workspaces.

  Reads all existing records in one `get_many/1` and writes them back in one
  `upsert_all/1`, so persisting a full workspace list costs two adapter round
  trips instead of the 2N that mapping `sync/1` would (one get + one upsert per
  workspace). Non-`Workspace` entries are skipped.
  """
  @spec sync_many([Workspace.t()]) :: {:ok, [WorkspaceRecord.t()]} | {:error, term()}
  def sync_many(workspaces) when is_list(workspaces) do
    records = for ws <- workspaces, match?(%Workspace{}, ws), do: build_record(ws)
    existing = impl().get_many(Enum.map(records, & &1.external_id))
    merged = Enum.map(records, &merge_into(Map.get(existing, &1.external_id), &1))
    impl().upsert_all(merged)
  end

  defp build_record(%Workspace{} = ws) do
    %WorkspaceRecord{
      external_id: external_id(ws),
      name: ws.name || ws.id,
      host_path: ws.path,
      status: ws.status && Atom.to_string(ws.status),
      manager_payload: sanitize_manager_payload(ws.metadata),
      last_seen_at: DateTime.utc_now()
    }
  end

  @doc "Persist the latest DB isolation snapshot (redacted summary only)."
  @spec persist_isolation(String.t(), DbIsolation.t()) ::
          {:ok, WorkspaceRecord.t()} | {:error, term()}
  def persist_isolation(external_id, %DbIsolation{} = iso) when is_binary(external_id) do
    base =
      case impl().get(external_id) do
        {:ok, existing} -> existing
        :error -> %WorkspaceRecord{external_id: external_id, name: external_id}
      end

    record = %{
      base
      | db_isolation: Atom.to_string(iso.isolation),
        db_isolation_source: Atom.to_string(iso.source),
        db_isolation_summary: iso.summary,
        db_isolation_detected_at: iso.detected_at,
        last_seen_at: DateTime.utc_now()
    }

    impl().upsert(record)
  end

  @doc "Persist a manual mode change. Returns the updated record."
  @spec set_mode(String.t(), WorkspaceMode.t()) :: {:ok, WorkspaceRecord.t()} | {:error, term()}
  def set_mode(external_id, mode)
      when is_binary(external_id) and
             mode in [:manual, :review, :agent_write_locked, :shared_stage_guarded] do
    base =
      case impl().get(external_id) do
        {:ok, existing} -> existing
        :error -> %WorkspaceRecord{external_id: external_id, name: external_id}
      end

    case impl().upsert(%{base | mode: Atom.to_string(mode), last_seen_at: DateTime.utc_now()}) do
      {:ok, _record} = ok ->
        broadcast_mode_changed(external_id, mode)
        ok

      other ->
        other
    end
  end

  def set_mode(_, _), do: {:error, :invalid_mode}

  @doc """
  Subscribes the caller to workspace mode changes for the given workspace.
  Delivers `{:workspace_mode_changed, external_id, mode}` after each
  successful `set_mode/2`.
  """
  @spec subscribe_mode_changes(String.t()) :: :ok | {:error, term()}
  def subscribe_mode_changes(external_id) when is_binary(external_id) do
    Phoenix.PubSub.subscribe(DevIde.PubSub, mode_topic(external_id))
  end

  defp broadcast_mode_changed(external_id, mode) do
    Phoenix.PubSub.broadcast(
      DevIde.PubSub,
      mode_topic(external_id),
      {:workspace_mode_changed, external_id, mode}
    )
  end

  defp mode_topic(external_id), do: "workspace_mode:" <> external_id

  @doc """
  Grants a time-boxed, explicit, revocable unlock allowing a server-spawned
  review-agent run to self-apply its own proposal without a per-change human
  click (`DevIDE.Proposals.AutoApply`). Never permanent — always has an
  expiry — and always attributable to the human who granted it.
  """
  @spec grant_agent_write_unlock(String.t(), DateTime.t(), String.t()) ::
          {:ok, WorkspaceRecord.t()} | {:error, term()}
  def grant_agent_write_unlock(external_id, %DateTime{} = until, granted_by)
      when is_binary(external_id) and is_binary(granted_by) do
    now = DateTime.utc_now()

    case impl().upsert(%{
           existing_or_new(external_id)
           | agent_write_unlocked_until: until,
             agent_write_unlocked_by: granted_by,
             agent_write_unlock_granted_at: now,
             last_seen_at: now
         }) do
      {:ok, _record} = ok ->
        broadcast_agent_write_unlock_changed(external_id, until, granted_by)
        ok

      other ->
        other
    end
  end

  @doc "The kill switch — clears the unlock immediately, effective for the next completed run."
  @spec revoke_agent_write_unlock(String.t()) :: {:ok, WorkspaceRecord.t()} | {:error, term()}
  def revoke_agent_write_unlock(external_id) when is_binary(external_id) do
    case impl().upsert(%{
           existing_or_new(external_id)
           | agent_write_unlocked_until: nil,
             agent_write_unlocked_by: nil
         }) do
      {:ok, _record} = ok ->
        broadcast_agent_write_unlock_changed(external_id, nil, nil)
        ok

      other ->
        other
    end
  end

  @doc """
  Live-reads whether an agent-write unlock is currently in effect. Always
  reads through to the adapter (never cached) — the whole point of a
  revocable unlock is that revoke takes effect immediately.
  """
  @spec agent_write_unlock_for(String.t()) ::
          {:active, DateTime.t(), String.t()} | :inactive | :expired
  def agent_write_unlock_for(external_id) when is_binary(external_id) do
    case impl().get(external_id) do
      {:ok, %WorkspaceRecord{agent_write_unlocked_until: nil}} ->
        :inactive

      {:ok, %WorkspaceRecord{agent_write_unlocked_until: until, agent_write_unlocked_by: by}} ->
        if DateTime.compare(until, DateTime.utc_now()) == :gt,
          do: {:active, until, by},
          else: :expired

      :error ->
        :inactive
    end
  end

  @doc """
  Subscribes the caller to agent-write-unlock changes for the given
  workspace. Delivers `{:agent_write_unlock_changed, external_id, until, by}`
  after each grant, revoke (until/by both `nil`), or passive expiry.
  """
  @spec subscribe_agent_write_unlock_changes(String.t()) :: :ok | {:error, term()}
  def subscribe_agent_write_unlock_changes(external_id) when is_binary(external_id) do
    Phoenix.PubSub.subscribe(DevIde.PubSub, agent_write_unlock_topic(external_id))
  end

  defp existing_or_new(external_id) do
    case impl().get(external_id) do
      {:ok, existing} -> existing
      :error -> %WorkspaceRecord{external_id: external_id, name: external_id}
    end
  end

  defp broadcast_agent_write_unlock_changed(external_id, until, by) do
    Phoenix.PubSub.broadcast(
      DevIde.PubSub,
      agent_write_unlock_topic(external_id),
      {:agent_write_unlock_changed, external_id, until, by}
    )
  end

  defp agent_write_unlock_topic(external_id), do: "workspace_agent_write_unlock:" <> external_id

  def get(external_id), do: impl().get(external_id)
  def list, do: impl().list()
  def delete(external_id), do: impl().delete(external_id)

  @doc """
  Batch lookup of persisted records by host path (one adapter round trip).

  Inputs are `Path.expand`-normalized and nil/empty entries dropped; result
  keys are the normalized paths. When several records share a host path the
  canonical one is chosen by `WorkspaceRecord.preferred/1`.
  """
  @spec records_for_host_paths([String.t() | nil]) ::
          %{optional(String.t()) => WorkspaceRecord.t()}
  def records_for_host_paths(host_paths) when is_list(host_paths) do
    host_paths
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> case do
      [] -> %{}
      normalized -> impl().records_for_host_paths(normalized)
    end
  end

  @doc """
  Resolves the effective mode and where it came from:
  `:config_override | :persisted | :default`.
  """
  @spec mode_for(String.t()) :: {WorkspaceMode.t(), :config_override | :persisted | :default}
  def mode_for(external_id) do
    overrides = Application.get_env(:dev_ide, :workspace_modes, %{})

    cond do
      Map.has_key?(overrides, external_id) ->
        {WorkspaceMode.resolve(external_id), :config_override}

      true ->
        case impl().get(external_id) do
          {:ok, %WorkspaceRecord{mode: m}} when is_binary(m) ->
            {string_to_mode(m), :persisted}

          _ ->
            {WorkspaceMode.resolve(nil), :default}
        end
    end
  end

  ## Sanitization

  @secret_value_keys ~w(database_url postgres_url pg_url db_url
                        password pgpassword postgres_password
                        secret token api_key)
  @env_array_keys ~w(env environment)

  @doc """
  Drop credential-bearing keys from a source-supplied payload before
  persisting. Removes top-level `database_url`/`password`/etc.,
  recursively scrubs nested maps, and replaces obviously credentialed
  values inside `env`/`environment` lists with redacted forms.
  """
  def sanitize_manager_payload(nil), do: %{}

  def sanitize_manager_payload(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> secret_key?(k) end)
    |> Enum.map(fn {k, v} -> {k, sanitize_value(k, v)} end)
    |> Map.new()
  end

  def sanitize_manager_payload(_), do: %{}

  defp sanitize_value(k, v) when is_binary(k) do
    if k in @env_array_keys, do: sanitize_env(v), else: deep_sanitize(v)
  end

  defp sanitize_value(_, v), do: deep_sanitize(v)

  defp deep_sanitize(map) when is_map(map), do: sanitize_manager_payload(map)
  defp deep_sanitize(list) when is_list(list), do: Enum.map(list, &deep_sanitize/1)
  defp deep_sanitize(other), do: other

  defp sanitize_env(list) when is_list(list) do
    Enum.map(list, fn
      bin when is_binary(bin) ->
        case String.split(bin, "=", parts: 2) do
          [k, _v] ->
            if secret_key?(k), do: "#{k}=[REDACTED]", else: bin

          _ ->
            bin
        end

      other ->
        deep_sanitize(other)
    end)
  end

  defp sanitize_env(other), do: deep_sanitize(other)

  defp secret_key?(k) when is_binary(k), do: String.downcase(k) in @secret_value_keys
  defp secret_key?(_), do: false

  ## Helpers

  defp external_id(%Workspace{id: id}) when is_binary(id) and id != "", do: id
  defp external_id(%Workspace{name: n}) when is_binary(n), do: n

  defp merge_existing(%WorkspaceRecord{external_id: ext} = incoming) do
    existing =
      case impl().get(ext) do
        {:ok, record} -> record
        :error -> nil
      end

    merge_into(existing, incoming)
  end

  # Fold the source-derived fields of `incoming` onto the persisted `existing`
  # record, preserving IDE-owned fields (mode, db_isolation, agent_write_*, id,
  # inserted_at). With no existing record the incoming one is inserted as-is.
  defp merge_into(nil, incoming), do: incoming

  defp merge_into(%WorkspaceRecord{} = existing, incoming) do
    %{
      existing
      | name: incoming.name,
        host_path: incoming.host_path || existing.host_path,
        status: incoming.status || existing.status,
        manager_payload: incoming.manager_payload,
        last_seen_at: incoming.last_seen_at
    }
  end

  defp string_to_mode("manual"), do: :manual
  defp string_to_mode("review"), do: :review
  defp string_to_mode("agent_write_locked"), do: :agent_write_locked
  defp string_to_mode("shared_stage_guarded"), do: :shared_stage_guarded
  defp string_to_mode(_), do: WorkspaceMode.resolve(nil)

  defp impl,
    do:
      Application.get_env(
        :dev_ide,
        :workspace_state_adapter,
        DevIDE.Workspaces.State.MemoryAdapter
      )
end
