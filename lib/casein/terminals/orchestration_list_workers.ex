defmodule Casein.Terminals.OrchestrationListWorkers do
  @moduledoc """
  Read-only compact fleet worker list (#384 M3).

  Projects an existing `FleetBoard` into scan-sized rows for orchestrators —
  pane, window, issue, agent_state, blocked_on kind, fleet_role, needs_you? —
  without re-classifying agent state. Reuses `OrchestrationStatus.tabs_from_topology/1`
  + `FleetBoard` on the MCP path.

  Optional filters (`:fleet_role`, `:needs_you_only`) apply after board projection.
  Liveness `unknown` never becomes idle (inherited from FleetBoard kind discipline).
  No scrollback, no shell, no mutations. `worker_launch`, durable graphs, and
  verifiers remain out of scope.
  """

  alias Casein.Terminals.FleetBoard

  @type row :: %{
          pane_id: String.t() | nil,
          window: String.t() | nil,
          window_id: String.t() | nil,
          issue: pos_integer() | nil,
          agent_state: String.t() | nil,
          blocked_on: map() | nil,
          fleet_role: String.t() | nil,
          needs_you?: boolean()
        }

  @type payload :: %{
          workspace_id: String.t(),
          session: String.t(),
          generated_at: String.t(),
          incomplete: boolean(),
          incomplete_reason: String.t() | nil,
          needs_you_observe_state: String.t(),
          total: non_neg_integer(),
          filtered_total: non_neg_integer(),
          workers: [row()],
          filters: map(),
          note: String.t()
        }

  @doc """
  Project a `FleetBoard.board/0` into compact worker rows.

  Options:

    * `:workspace_id` / `:session` — required identity on the payload
    * `:now` — `DateTime` for `generated_at` (default utc_now)
    * `:fleet_role` — optional `"manager"` | `"worker"` (atom or string) filter
    * `:needs_you_only` — when true, keep only `needs_you?` rows
    * `:incomplete` / `:incomplete_reason` — snapshot miss or partial refresh
  """
  @spec project(FleetBoard.board(), keyword()) :: payload()
  def project(board, opts \\ []) when is_map(board) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    session = Keyword.fetch!(opts, :session)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    fleet_role = normalize_role_filter(Keyword.get(opts, :fleet_role))
    needs_you_only? = Keyword.get(opts, :needs_you_only) == true
    incomplete? = Keyword.get(opts, :incomplete) == true
    incomplete_reason = Keyword.get(opts, :incomplete_reason)

    all_rows = Enum.map(Map.get(board, :rows) || [], &compact_row/1)

    workers =
      all_rows
      |> filter_fleet_role(fleet_role)
      |> filter_needs_you(needs_you_only?)

    %{
      workspace_id: workspace_id,
      session: session,
      generated_at: DateTime.to_iso8601(now),
      incomplete: incomplete?,
      incomplete_reason: incomplete_reason,
      needs_you_observe_state: if(incomplete?, do: "unknown", else: "ok"),
      total: Map.get(board, :total, length(all_rows)),
      filtered_total: length(workers),
      workers: workers,
      filters: filters_json(fleet_role, needs_you_only?),
      note:
        "M3 compact worker list. Reuses FleetBoard/OrchestrationStatus.tabs_from_topology. " <>
          "needs_you_observe_state=unknown means the snapshot could not be computed, " <>
          "not that nobody needs you. liveness unknown ≠ idle. " <>
          "worker_launch, durable graphs, and verifiers remain out of scope."
    }
  end

  ## Internals

  defp compact_row(row) when is_map(row) do
    blocked = blocked_on_json(Map.get(row, :blocked_on))

    %{
      pane_id: Map.get(row, :pane_id),
      window: Map.get(row, :display_name) || Map.get(row, :name),
      window_id: Map.get(row, :window_id),
      issue: Map.get(row, :issue),
      agent_state: atom_or_nil(Map.get(row, :agent_state)),
      blocked_on: blocked,
      fleet_role: atom_or_nil(Map.get(row, :fleet_role)),
      needs_you?: Map.get(row, :needs_you?) == true
    }
    |> reject_nils()
  end

  defp filter_fleet_role(rows, nil), do: rows

  defp filter_fleet_role(rows, role) when is_binary(role) do
    Enum.filter(rows, fn row -> Map.get(row, :fleet_role) == role end)
  end

  defp filter_needs_you(rows, false), do: rows
  defp filter_needs_you(rows, true), do: Enum.filter(rows, &(&1[:needs_you?] == true))

  defp filters_json(fleet_role, needs_you_only?) do
    %{
      fleet_role: fleet_role,
      needs_you_only: needs_you_only?
    }
    |> reject_nils()
  end

  defp normalize_role_filter(nil), do: nil
  defp normalize_role_filter(:manager), do: "manager"
  defp normalize_role_filter(:worker), do: "worker"
  defp normalize_role_filter("manager"), do: "manager"
  defp normalize_role_filter("worker"), do: "worker"
  defp normalize_role_filter(_), do: nil

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

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_or_nil(value) when is_binary(value), do: value
  defp atom_or_nil(_), do: nil

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
