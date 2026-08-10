defmodule Casein.Terminals.OrchestrationStatus do
  @moduledoc """
  Read-only MCP projection of the operator fleet board (#384 M0).

  Reuses `FleetBoard` / `GateQueue` / `OrphanedClaims` — does not re-classify
  agent state. Wire shape is intentionally small: bucket counts, gate depth,
  orphaned claims, and one row per fleet window (pane, issue, state, role).
  No scrollback, no shell, no mutations.

  `worker_launch`, durable task graphs, path contracts, and verifier adapters
  remain out of scope.
  """

  alias Casein.Ops.GateQueue
  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.OrphanedClaims

  @type payload :: %{
          workspace_id: String.t(),
          session: String.t(),
          generated_at: String.t(),
          total: non_neg_integer(),
          attention_count: non_neg_integer(),
          counts: map(),
          gate_queue: map(),
          orphaned_claims: map(),
          rows: [map()],
          note: String.t()
        }

  @doc """
  Project a `FleetBoard.board/0` into a JSON-friendly orchestration_status map.

  Options:

    * `:workspace_id` / `:session` — required identity on the payload
    * `:now` — `DateTime` for `generated_at` (default utc_now)
  """
  @spec project(FleetBoard.board(), keyword()) :: payload()
  def project(board, opts \\ []) when is_map(board) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    session = Keyword.fetch!(opts, :session)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    %{
      workspace_id: workspace_id,
      session: session,
      generated_at: DateTime.to_iso8601(now),
      total: Map.get(board, :total, 0),
      attention_count: Map.get(board, :attention_count, 0),
      counts: counts_json(Map.get(board, :counts) || %{}),
      gate_queue: gate_json(Map.get(board, :gate_queue) || GateQueue.unknown()),
      orphaned_claims: orphans_json(Map.get(board, :orphaned_claims) || OrphanedClaims.unknown()),
      rows: Enum.map(Map.get(board, :rows) || [], &row_json/1),
      note:
        "M0 read-only fleet status. Reuses FleetBoard/GateQueue/OrphanedClaims. " <>
          "worker_launch, durable graphs, path contracts, and verifiers are out of scope."
    }
  end

  @doc """
  Build fleet-board window tabs from an enriched topology (MCP path).

  Expects panes already carrying AgentState / IssueBinding / FleetChrome fields
  (as produced by `TerminalTools.Impl.Session.topology/1`). Pure — no tmux.
  """
  @spec tabs_from_topology(map()) :: [map()]
  def tabs_from_topology(%{windows: windows, panes: panes})
      when is_list(windows) and is_list(panes) do
    panes_by_window =
      panes
      |> Enum.group_by(fn pane ->
        Map.get(pane, :window_id) || Map.get(pane, "window_id")
      end)

    Enum.map(windows, fn window ->
      window_id = Map.get(window, :id) || Map.get(window, "id")
      wpanes = Map.get(panes_by_window, window_id) || []
      agent = pick_agent_pane(wpanes)

      %{
        id: window_id,
        name: Map.get(window, :name) || Map.get(window, "name") || window_id,
        display_name:
          Map.get(window, :name) || Map.get(window, "name") ||
            Map.get(agent || %{}, :window_name) || window_id,
        active?: truthy?(Map.get(window, :active) || Map.get(window, "active")),
        agent_state: pane_field(agent, :agent_state),
        agent_state_message: pane_field(agent, :agent_state_message),
        agent_pane_id: pane_field(agent, :id),
        label: pane_field(agent, :label),
        issue: pane_field(agent, :issue) || Map.get(window, :issue) || Map.get(window, "issue"),
        issue_title: pane_field(agent, :issue_title),
        task_summary: pane_field(agent, :task_summary),
        fleet_role: pane_field(agent, :fleet_role) || Map.get(window, :fleet_role),
        fleet_readiness: pane_field(agent, :fleet_readiness) || Map.get(window, :fleet_readiness),
        ready_no_task_for_seconds:
          pane_field(agent, :ready_no_task_for_seconds) ||
            Map.get(window, :ready_no_task_for_seconds),
        quiet?: false,
        unseen_quiet?: false
      }
    end)
  end

  def tabs_from_topology(_), do: []

  ## Internals

  defp pick_agent_pane(panes) do
    Enum.find(panes, &agent_role?/1) ||
      Enum.find(panes, fn p -> not is_nil(pane_field(p, :agent_state)) end) ||
      List.first(panes)
  end

  defp agent_role?(pane) do
    role = pane_field(pane, :role)
    role in ["agent", :agent]
  end

  defp pane_field(nil, _key), do: nil

  defp pane_field(pane, key) when is_map(pane) do
    Map.get(pane, key) || Map.get(pane, Atom.to_string(key))
  end

  defp counts_json(counts) do
    FleetBoard.bucket_order()
    |> Map.new(fn bucket ->
      {Atom.to_string(bucket), Map.get(counts, bucket, 0)}
    end)
  end

  defp gate_json(%{lock_state: state} = gate) do
    %{
      observe_state: gate_observe_state(state),
      lock_state: atom_or_nil(state),
      depth: Map.get(gate, :depth),
      waiter_count: Map.get(gate, :waiter_count),
      summary: GateQueue.summary(gate),
      holder: holder_json(Map.get(gate, :holder)),
      waiters: Enum.map(Map.get(gate, :waiters) || [], &holder_json/1)
    }
  end

  defp gate_json(_), do: gate_json(GateQueue.unknown())

  defp gate_observe_state(:unknown), do: "unknown"
  defp gate_observe_state(:free), do: "ok"
  defp gate_observe_state(:held), do: "ok"
  defp gate_observe_state(_), do: "unknown"

  defp holder_json(nil), do: nil

  defp holder_json(holder) when is_map(holder) do
    %{
      pid: Map.get(holder, :pid),
      pr: Map.get(holder, :pr),
      branch: Map.get(holder, :branch),
      run_id: Map.get(holder, :run_id),
      sha: Map.get(holder, :sha),
      workflow: Map.get(holder, :workflow),
      held_for_seconds: Map.get(holder, :held_for_seconds),
      cmd: Map.get(holder, :cmd)
    }
    |> reject_nils()
  end

  defp orphans_json(%{observe_state: state} = snap) do
    %{
      observe_state: atom_or_nil(state) || "unknown",
      reason: atom_or_nil(Map.get(snap, :reason)),
      orphan_count: Map.get(snap, :orphan_count),
      claimed_count: Map.get(snap, :claimed_count),
      bound_count: Map.get(snap, :bound_count),
      summary: OrphanedClaims.summary(snap),
      orphans:
        Enum.map(Map.get(snap, :orphans) || [], fn orphan ->
          %{
            number: Map.get(orphan, :number),
            title: Map.get(orphan, :title),
            url: Map.get(orphan, :url),
            priority: Map.get(orphan, :priority),
            needs_you?: true,
            attention_reason: "orphaned_claim"
          }
          |> reject_nils()
        end)
    }
  end

  defp orphans_json(_), do: orphans_json(OrphanedClaims.unknown())

  defp row_json(row) when is_map(row) do
    %{
      window_id: Map.get(row, :window_id),
      pane_id: Map.get(row, :pane_id),
      name: Map.get(row, :display_name) || Map.get(row, :name),
      agent_state: atom_or_nil(Map.get(row, :agent_state)),
      agent_state_message: Map.get(row, :agent_state_message),
      issue: Map.get(row, :issue),
      issue_title: Map.get(row, :issue_title),
      fleet_role: atom_or_nil(Map.get(row, :fleet_role)),
      fleet_readiness: atom_or_nil(Map.get(row, :fleet_readiness)),
      ready_no_task_for_seconds: Map.get(row, :ready_no_task_for_seconds),
      needs_you?: Map.get(row, :needs_you?) == true,
      attention_reason: atom_or_nil(Map.get(row, :attention_reason)),
      bucket: atom_or_nil(Map.get(row, :bucket)),
      active?: Map.get(row, :active?) == true
    }
    |> reject_nils()
  end

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_or_nil(value) when is_binary(value), do: value
  defp atom_or_nil(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
