defmodule DevIDE.Terminals.WorkspaceAccessCache do
  @moduledoc """
  Short-lived cache for `Workspaces.get/2` results used on terminal reconnect.

  Fast-path joins still re-check workspace access on every channel join; this
  module only avoids repeated manager HTTP round-trips within the TTL window.

  ## ETS table access

  The underlying named ETS table is intentionally :public (controlled by
  `config :dev_ide, :ets_table_access`). TerminalChannel and other connection
  processes must be able to insert verified claims for fast reconnects. Only
  trusted application code paths ever write to it (after Phoenix.Token
  verification + claim enrichment + mode checks). The node is assumed to run
  only trusted code; do not allow arbitrary user-provided code or NIFs to
  execute in the main BEAM node if you need a stronger boundary.
  """

  @table :dev_ide_workspace_access_cache
  @ttl_ms 60_000

  @doc false
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        access = Application.get_env(:dev_ide, :ets_table_access, :protected)

        :ets.new(@table, [
          :named_table,
          access,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  end

  @spec fetch(String.t(), String.t() | nil, (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(workspace_id, email, fetch_fun)
      when is_binary(workspace_id) and is_function(fetch_fun, 0) do
    ensure_table!()
    key = {workspace_id, email || ""}
    now = System.system_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, ws, expires_at}] when is_integer(expires_at) and expires_at > now ->
        {:ok, ws}

      _ ->
        case fetch_fun.() do
          {:ok, _} = ok ->
            :ets.insert(@table, {key, elem(ok, 1), now + @ttl_ms})
            ok

          other ->
            :ets.delete(@table, key)
            other
        end
    end
  end

  @doc false
  def reset! do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end
end
