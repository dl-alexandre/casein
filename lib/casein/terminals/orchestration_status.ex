defmodule Casein.Terminals.OrchestrationStatus do
  @moduledoc """
  Read-only MCP projection of the operator fleet board (#384 M1).

  Reuses `FleetBoard` / `GateQueue` / `OrphanedClaims` — does not re-classify
  agent state. Wire shape answers the operator questions that cost real time:

    * which workers are blocked, and on what (`blocked_on` + message)
    * where am I in the gate queue (`gate_queue` depth + positions + `position/2`)
    * is this pane working or wedged (`liveness` external observation; unknown ≠ quiet)

  No scrollback, no shell, no mutations. `worker_launch`, durable task graphs,
  path contracts, and verifier adapters remain out of scope.
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
          blocked: [map()],
          note: String.t()
        }

  @doc """
  Project a `FleetBoard.board/0` into a JSON-friendly orchestration_status map.

  Options:

    * `:workspace_id` / `:session` — required identity on the payload
    * `:now` — `DateTime` for `generated_at` (default utc_now)
    * `:gate_identity` — optional PR/run/branch/pid for `gate_queue.my_position`
  """
  @spec project(FleetBoard.board(), keyword()) :: payload()
  def project(board, opts \\ []) when is_map(board) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    session = Keyword.fetch!(opts, :session)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    rows = Enum.map(Map.get(board, :rows) || [], &row_json/1)

    %{
      workspace_id: workspace_id,
      session: session,
      generated_at: DateTime.to_iso8601(now),
      total: Map.get(board, :total, 0),
      attention_count: Map.get(board, :attention_count, 0),
      counts: counts_json(Map.get(board, :counts) || %{}),
      gate_queue: gate_json(Map.get(board, :gate_queue) || GateQueue.unknown(), opts),
      orphaned_claims: orphans_json(Map.get(board, :orphaned_claims) || OrphanedClaims.unknown()),
      rows: rows,
      blocked: Enum.filter(rows, &blocked_row?/1),
      note:
        "M1 operator fleet status. Reuses FleetBoard/GateQueue/OrphanedClaims. " <>
          "liveness unknown ≠ quiet; bare unknown is forbidden — rows carry unknown_reason. " <>
          "Counts are NOT the same population: topology panes = all panes in the session; " <>
          "fleet board total/rows = agent/worker/manager windows only (shells excluded); " <>
          "fleet_role=worker is a subset of board rows; badge \"fleet · N\" uses board attention " <>
          "and working-ish buckets, not raw pane count. SUP/MGR panes are legitimately not workers. " <>
          "gate position via gate_queue.my_position when identity given. " <>
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
        liveness: pane_field(agent, :liveness),
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

  defp gate_json(gate, opts)

  defp gate_json(%{lock_state: state} = gate, opts) when is_list(opts) do
    positioned = GateQueue.with_positions(gate)
    identity = Keyword.get(opts, :gate_identity)
    my_position = GateQueue.position(positioned, identity)

    %{
      observe_state: gate_observe_state(state),
      lock_state: atom_or_nil(state),
      depth: Map.get(positioned, :depth),
      waiter_count: Map.get(positioned, :waiter_count),
      summary: GateQueue.summary(positioned),
      holder: holder_json(Map.get(positioned, :holder)),
      waiters: Enum.map(Map.get(positioned, :waiters) || [], &holder_json/1),
      my_position: position_json(my_position)
    }
  end

  defp gate_json(_, opts) when is_list(opts), do: gate_json(GateQueue.unknown(), opts)
  defp gate_json(gate, _), do: gate_json(gate, [])

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
      cmd: Map.get(holder, :cmd),
      position: Map.get(holder, :position)
    }
    |> reject_nils()
  end

  defp position_json(pos) when is_map(pos) do
    status = Map.get(pos, :status)

    %{
      status: atom_or_nil(status) || "unknown",
      position: Map.get(pos, :position),
      depth: Map.get(pos, :depth),
      ahead: Map.get(pos, :ahead),
      waiter_count: Map.get(pos, :waiter_count),
      holder: holder_json(Map.get(pos, :holder)),
      self: holder_json(Map.get(pos, :self)),
      waiters: Enum.map(Map.get(pos, :waiters) || [], &holder_json/1)
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
      unknown_reason: unknown_reason_json(Map.get(row, :unknown_reason)),
      active?: Map.get(row, :active?) == true,
      liveness: liveness_json(Map.get(row, :liveness)),
      blocked_on: blocked_on_json(Map.get(row, :blocked_on))
    }
    |> reject_nils()
  end

  defp blocked_row?(%{blocked_on: %{} = blocked}) when map_size(blocked) > 0, do: true

  defp blocked_row?(%{agent_state: state}) when state in ["blocked", "errored", "stalled"],
    do: true

  defp blocked_row?(%{needs_you?: true, attention_reason: reason})
       when reason in ["blocked", "errored", "stalled"],
       do: true

  defp blocked_row?(_), do: false

  defp liveness_json(nil), do: nil

  defp liveness_json(live) when is_map(live) do
    state = atom_or_nil(Map.get(live, :state) || Map.get(live, "state"))

    %{
      state: state || "unknown",
      reason: atom_or_nil(Map.get(live, :reason) || Map.get(live, "reason")),
      quiet_for_seconds: Map.get(live, :quiet_for_seconds) || Map.get(live, "quiet_for_seconds"),
      last_write_at: Map.get(live, :last_write_at) || Map.get(live, "last_write_at"),
      commit_count: Map.get(live, :commit_count) || Map.get(live, "commit_count")
    }
    |> reject_nils()
  end

  defp liveness_json(_), do: %{state: "unknown", reason: "malformed"}

  defp blocked_on_json(nil), do: nil

  defp blocked_on_json(blocked) when is_map(blocked) do
    %{
      kind: atom_or_nil(Map.get(blocked, :kind) || Map.get(blocked, "kind")),
      reason: atom_or_nil(Map.get(blocked, :reason) || Map.get(blocked, "reason")),
      detail: Map.get(blocked, :detail) || Map.get(blocked, "detail")
    }
    |> reject_nils()
  end

  defp blocked_on_json(_), do: nil

  # Bare unknown is the silent-failure class — always stringify a reason.
  defp unknown_reason_json(nil), do: nil
  defp unknown_reason_json(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp unknown_reason_json(reason) when is_binary(reason), do: reason

  defp unknown_reason_json({:liveness_unknown, inner}) do
    "liveness_unknown:#{atom_or_nil(inner) || "unscanned"}"
  end

  defp unknown_reason_json({:unmapped_agent_state, state}) do
    "unmapped_agent_state:#{atom_or_nil(state) || "nil"}"
  end

  defp unknown_reason_json(other), do: inspect(other)

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
