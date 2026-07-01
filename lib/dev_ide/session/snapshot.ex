defmodule DevIDE.Session.Snapshot do
  @moduledoc """
  Read-only projection of a workspace's *live supervisory state* for the
  mobile companion (v1a: push-driven awareness + glanceable oversight).

  This is a pure fold over state the runtime already emits — no new tables,
  no new ownership. The runtime owns the session; this is just a view:

    * `mode`            — `DevIDE.Workspaces.State.mode_for/1`
    * `current_run`     — newest entry from `DevIDE.Runs.Ledger.recent_runs_for/2`
    * `recent_runs`     — the rest of that ledger window
    * `last_decision`   — newest `policy.*` row via `DevIDE.Audit`
    * `recent_audit`    — `DevIDE.Audit.recent_for/2`
    * `active_agents`   — `DevIDE.Agents.Activity.recent/2`
    * `pending_reviews` — best-effort count from `DevIDE.Proposals` (read-only)

  `build/1` is what `DevIdeWeb.SessionChannel` returns on join and re-runs
  (debounced) when a live delta arrives.
  """

  alias DevIDE.{Audit, Proposals}
  alias DevIDE.Agents.Activity
  alias DevIDE.Runs.Ledger
  alias DevIDE.Workspaces.State

  @type t :: %__MODULE__{
          workspace_id: String.t(),
          mode: atom(),
          mode_source: :config_override | :persisted | :default,
          current_run: map() | nil,
          recent_runs: [map()],
          last_decision: decision() | nil,
          recent_audit: [audit_row()],
          active_agents: [map()],
          pending_reviews: non_neg_integer(),
          updated_at: DateTime.t()
        }

  @type decision :: %{
          action: String.t(),
          decision: :allow | :deny | nil,
          reason: atom() | nil,
          mode: any(),
          at: DateTime.t()
        }

  @type audit_row :: %{
          action: String.t(),
          decision: :allow | :deny | nil,
          reason: atom() | nil,
          target_ref: String.t() | nil,
          at: DateTime.t()
        }

  @enforce_keys [:workspace_id, :mode, :updated_at]
  defstruct workspace_id: nil,
            mode: :manual,
            mode_source: :default,
            current_run: nil,
            recent_runs: [],
            last_decision: nil,
            recent_audit: [],
            active_agents: [],
            pending_reviews: 0,
            updated_at: nil

  @default_run_window 10
  @default_audit_window 8
  @default_agent_window 8

  @spec build(String.t(), keyword()) :: t()
  def build(workspace_id, opts \\ []) when is_binary(workspace_id) do
    {mode, mode_source} = State.mode_for(workspace_id)

    runs = Ledger.recent_runs_for(workspace_id, Keyword.get(opts, :runs, @default_run_window))

    %__MODULE__{
      workspace_id: workspace_id,
      mode: mode,
      mode_source: mode_source,
      current_run: List.first(runs),
      recent_runs: Enum.drop(runs, 1),
      last_decision: last_decision(workspace_id),
      recent_audit:
        workspace_id
        |> Audit.recent_for(Keyword.get(opts, :audit, @default_audit_window))
        |> Enum.map(&audit_row/1),
      active_agents:
        Activity.recent(workspace_id, Keyword.get(opts, :agents, @default_agent_window)),
      pending_reviews: pending_reviews(workspace_id),
      updated_at: Keyword.get(opts, :now) || DateTime.utc_now()
    }
  end

  defp last_decision(workspace_id) do
    case Audit.recent_with_action_prefix(workspace_id, "policy.", 1) do
      [event | _] ->
        %{
          action: event.action,
          decision: event.decision,
          reason: event.reason,
          mode: Map.get(event.metadata || %{}, "mode") || Map.get(event.metadata || %{}, :mode),
          at: event.inserted_at
        }

      _ ->
        nil
    end
  end

  defp audit_row(event) do
    %{
      action: event.action,
      decision: event.decision,
      reason: event.reason,
      target_ref: event.target_ref,
      at: event.inserted_at
    }
  end

  # Best-effort: proposals are filesystem-discovered under the workspace root.
  # If we have no observed host_path yet, report 0 rather than guessing.
  defp pending_reviews(workspace_id) do
    with {:ok, %{host_path: path}} when is_binary(path) <- State.get(workspace_id),
         proposals when is_list(proposals) <- safe_discover(path) do
      length(proposals)
    else
      _ -> 0
    end
  end

  defp safe_discover(path) do
    Proposals.discover(path)
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
