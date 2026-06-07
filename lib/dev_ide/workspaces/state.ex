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
    record = %WorkspaceRecord{
      external_id: external_id(ws),
      name: ws.name || ws.id,
      host_path: ws.path,
      status: ws.status && Atom.to_string(ws.status),
      manager_payload: sanitize_manager_payload(ws.metadata),
      last_seen_at: DateTime.utc_now()
    }

    impl().upsert(merge_existing(record))
  end

  def sync(other), do: {:error, {:not_a_workspace, other}}

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

    impl().upsert(%{base | mode: Atom.to_string(mode), last_seen_at: DateTime.utc_now()})
  end

  def set_mode(_, _), do: {:error, :invalid_mode}

  def get(external_id), do: impl().get(external_id)
  def list, do: impl().list()
  def delete(external_id), do: impl().delete(external_id)

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
    case impl().get(ext) do
      {:ok, existing} ->
        %{
          existing
          | name: incoming.name,
            host_path: incoming.host_path || existing.host_path,
            status: incoming.status || existing.status,
            manager_payload: incoming.manager_payload,
            last_seen_at: incoming.last_seen_at
        }

      :error ->
        incoming
    end
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
