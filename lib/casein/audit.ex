defmodule Casein.Audit do
  @moduledoc """
  Audit log for sensitive UI actions and policy decisions.

  This is backed by `Casein.Audit.EctoAdapter` by default, and uses
  `Casein.Audit.MemoryAdapter` for testing.
  """

  require Logger

  alias Casein.Audit.Event

  @topic_prefix "audit:"

  @spec emit(map()) :: {:ok, Event.t()} | {:error, term()}
  def emit(attrs) when is_map(attrs) do
    event = attrs |> Casein.Signals.Context.stamp() |> Event.new()

    case impl().record(event) do
      :ok ->
        Casein.Signals.Context.advance(event.id)
        broadcast(event)
        {:ok, event}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Subscribe to live audit events for a workspace.

  Delivers `{:audit_event, %Casein.Audit.Event{}}` for every event emitted
  with a matching `workspace_id` — this is the live spine for the mobile
  session companion (run state, policy decisions, ledger highlights). Mode
  changes and agent MCP activity broadcast on their own topics
  (`Casein.Workspaces.State.subscribe_mode_changes/1`,
  `Casein.Agents.Activity.subscribe/1`).
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(Casein.PubSub, topic(workspace_id))
  end

  @spec topic(String.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: @topic_prefix <> workspace_id

  defp broadcast(%Event{workspace_id: workspace_id} = event) when is_binary(workspace_id) do
    Phoenix.PubSub.broadcast(Casein.PubSub, topic(workspace_id), {:audit_event, event})
    Casein.Signals.Publish.audit_event(event)
  end

  defp broadcast(_event), do: :ok

  @doc """
  Emit and ignore failures — for fire-and-forget audit calls.

  Absorbs exceptions as well as `{:error, _}` returns: `emit!/1` runs inside
  GenServer hot paths (`AgentState.Server`, `PgProbe`, `SituationServer`,
  `PollerWatcher`), where a `Repo.insert` raise during a Postgres outage must
  never crash the emitting process — least of all the probe that exists to
  report Postgres trouble.
  """
  @spec emit!(map()) :: Event.t() | nil
  def emit!(attrs) do
    case emit(attrs) do
      {:ok, e} -> e
      _ -> nil
    end
  rescue
    error ->
      Logger.warning("[audit] emit! failed: #{Exception.message(error)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("[audit] emit! exited: #{inspect(reason)}")
      nil
  end

  def list(opts \\ []), do: impl().list(opts)
  def recent_for(workspace_id, n \\ 50), do: impl().recent_for(workspace_id, n)

  @doc """
  Recent events for a workspace whose `action` starts with `action_prefix`.

  Lets ledger-style readers pull only their own event family (e.g. `"run."`)
  via the `[action, inserted_at]` index instead of over-fetching the whole
  audit stream and filtering in memory.
  """
  def recent_with_action_prefix(workspace_id, action_prefix, n)
      when is_binary(action_prefix) do
    impl().recent_with_action_prefix(workspace_id, action_prefix, n)
  end

  @doc """
  Recent events for a workspace recorded by a specific tool, newest first.

  `tool` is the indexed `audit_events.tool` column stamped by
  `Casein.Agents.MCPAudit` (e.g. `"terminal_send_command"`), so per-tool
  timelines don't need to LIKE-match action strings.
  """
  def recent_for_tool(workspace_id, tool, n \\ 50)
      when is_binary(workspace_id) and is_binary(tool) do
    impl().recent_for_tool(workspace_id, tool, n)
  end

  @doc """
  Events sharing a correlation id, ascending by `inserted_at` (chain order).

  Correlation ids are stamped into event metadata by
  `Casein.Signals.Context` when an entry point (MCP tool call, deploy
  webhook, run start) established a causality context.
  """
  @spec list_by_correlation(String.t()) :: [Event.t()]
  def list_by_correlation(correlation_id) when is_binary(correlation_id),
    do: impl().list_by_correlation(correlation_id)

  def clear, do: impl().clear()

  ## Convenience helpers

  def emit_decision(%Casein.Policy.Decision{} = d, attrs) do
    emit!(
      Map.merge(attrs, %{
        action: action_name(d, attrs),
        decision: d.verdict,
        reason: d.reason,
        metadata: Map.merge(Map.get(attrs, :metadata, %{}), %{mode: d.mode})
      })
    )
  end

  defp action_name(%{verdict: :deny}, _), do: "policy.blocked"

  defp action_name(%{action: action}, attrs) do
    Map.get(attrs, :action) || Atom.to_string(action)
  end

  defp impl, do: Application.get_env(:casein, :audit_adapter, Casein.Audit.MemoryAdapter)
end
