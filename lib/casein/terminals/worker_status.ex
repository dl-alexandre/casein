defmodule Casein.Terminals.WorkerStatus do
  @moduledoc """
  Read-only single-worker deep status (#384 M2).

  Inverse of `OrchestrationStatus` (fleet aggregate): given one pane, project
  the already-enriched topology fields into a structured wire payload.

  Reuses `FleetBoard` row shaping for `blocked_on` / liveness kind discipline —
  report-only (`blocked`/`errored`) stays distinct from derived-only (`stalled`);
  liveness `unknown` never becomes quiet/idle. No scrollback, no shell, and no
  mutations. A `worker_launch` work handle is joined when one was recorded.
  """

  alias Casein.Terminals.FleetBoard

  @type payload :: %{
          workspace_id: String.t(),
          session: String.t(),
          generated_at: String.t(),
          found?: boolean(),
          pane_id: String.t() | nil,
          window_id: String.t() | nil,
          window_name: String.t() | nil,
          fleet_role: String.t() | nil,
          fleet_readiness: String.t() | nil,
          ready_no_task_for_seconds: non_neg_integer() | nil,
          agent_state: String.t() | nil,
          agent_state_message: String.t() | nil,
          issue: pos_integer() | nil,
          issue_title: String.t() | nil,
          task_summary: String.t() | nil,
          label: String.t() | nil,
          worktree_path: String.t() | nil,
          needs_you?: boolean() | nil,
          attention_reason: String.t() | nil,
          bucket: String.t() | nil,
          liveness: map() | nil,
          blocked_on: map() | nil,
          note: String.t()
        }

  @doc """
  Project an enriched topology into a single-worker status payload.

  Options:

    * `:workspace_id` / `:session` / `:pane` — required identity
    * `:window_id` — optional disambiguator when the same pane id is unexpected
    * `:now` — `DateTime` for `generated_at` (default utc_now)
  """
  @spec project(map(), keyword()) :: payload()
  def project(topology, opts \\ []) when is_map(topology) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    session = Keyword.fetch!(opts, :session)
    pane_id = Keyword.fetch!(opts, :pane)
    window_id = Keyword.get(opts, :window_id)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    case find_pane(topology, pane_id, window_id) do
      nil ->
        not_found(workspace_id, session, pane_id, window_id, now)

      pane ->
        found(workspace_id, session, pane, topology, now)
    end
  end

  @doc false
  @spec find_pane(map(), String.t(), String.t() | nil) :: map() | nil
  def find_pane(%{panes: panes}, pane_id, window_id)
      when is_list(panes) and is_binary(pane_id) do
    panes
    |> Enum.find(fn pane ->
      id = pane_field(pane, :id)
      id == pane_id and window_matches?(pane, window_id)
    end)
  end

  def find_pane(_, _, _), do: nil

  ## Internals

  defp found(workspace_id, session, pane, topology, now) do
    window = window_for(pane, topology)
    tab = tab_from_pane(pane, window)
    board = FleetBoard.from_window_tabs([tab], gate_queue: unknown_gate(), claimed: [])
    row = List.first(board.rows) || %{}

    resolution =
      Map.get(row, :agent_state_resolution) || pane_field(pane, :agent_state_resolution)

    last_reported =
      Map.get(row, :agent_state_last_reported) || pane_field(pane, :agent_state_last_reported)

    reported_at =
      Map.get(row, :agent_state_reported_at) || pane_field(pane, :agent_state_reported_at)

    age_s = Map.get(row, :agent_state_age_s) || pane_field(pane, :agent_state_age_s)

    # Prefer FleetBoard row projection (blocked_on / liveness / bucket) when the
    # pane qualifies as a fleet row; otherwise emit pane fields directly so a
    # non-agent pane still returns identity + worktree without inventing state.
    base = %{
      workspace_id: workspace_id,
      session: session,
      generated_at: DateTime.to_iso8601(now),
      found?: true,
      pane_id: pane_field(pane, :id),
      window_id: pane_field(pane, :window_id) || Map.get(window || %{}, :id),
      window_name:
        pane_field(pane, :window_name) || Map.get(window || %{}, :name) ||
          Map.get(window || %{}, "name"),
      fleet_role: atom_or_nil(Map.get(row, :fleet_role) || pane_field(pane, :fleet_role)),
      fleet_readiness:
        atom_or_nil(Map.get(row, :fleet_readiness) || pane_field(pane, :fleet_readiness)),
      ready_no_task_for_seconds:
        Map.get(row, :ready_no_task_for_seconds) || pane_field(pane, :ready_no_task_for_seconds),
      agent_state:
        atom_or_nil(
          Map.get(row, :agent_state) || pane_field(pane, :agent_state) ||
            work_handle_status(pane, :state)
        ),
      status:
        Map.get(row, :status) ||
          FleetBoard.operational_status(%{
            agent_state: pane_field(pane, :agent_state),
            liveness: pane_field(pane, :liveness)
          }),
      agent_state_message:
        Map.get(row, :agent_state_message) || pane_field(pane, :agent_state_message) ||
          work_handle_status(pane, :message),
      agent_state_resolution: atom_or_nil(resolution),
      agent_state_last_reported: atom_or_nil(last_reported),
      agent_state_reported_at: reported_at,
      agent_state_age_s: age_s,
      agent_state_note: agent_state_note(resolution, last_reported, age_s),
      issue: Map.get(row, :issue) || pane_field(pane, :issue),
      issue_title: Map.get(row, :issue_title) || pane_field(pane, :issue_title),
      task_summary: Map.get(row, :task_summary) || pane_field(pane, :task_summary),
      label: Map.get(row, :label) || pane_field(pane, :label),
      worktree_path: blank_to_nil(pane_field(pane, :worktree_path)),
      needs_you?: Map.get(row, :needs_you?),
      attention_reason: atom_or_nil(Map.get(row, :attention_reason)),
      bucket: atom_or_nil(Map.get(row, :bucket)),
      liveness: liveness_json(Map.get(row, :liveness) || pane_field(pane, :liveness)),
      blocked_on: blocked_on_json(Map.get(row, :blocked_on)),
      work_handle: Map.get(row, :work_handle) || pane_field(pane, :work_handle),
      note:
        "M2 single-worker status. Reuses FleetBoard blocked_on/liveness kind discipline. " <>
          "liveness unknown ≠ quiet. agent_state_resolution says why agent_state is " <>
          "present or absent (report | derived | expired_report | unreported); an " <>
          "expired_report still carries agent_state_last_reported / agent_state_reported_at. " <>
          "Recorded worker_launch identity is included; task graphs and verifiers remain " <>
          "out of scope."
    }

    reject_nils(base)
  end

  defp not_found(workspace_id, session, pane_id, window_id, now) do
    %{
      workspace_id: workspace_id,
      session: session,
      generated_at: DateTime.to_iso8601(now),
      found?: false,
      pane_id: pane_id,
      window_id: window_id,
      note: "M2 single-worker status: pane not found in session topology."
    }
    |> reject_nils()
  end

  defp tab_from_pane(pane, window) do
    window_id = pane_field(pane, :window_id) || Map.get(window || %{}, :id) || "unknown"

    %{
      id: window_id,
      name:
        pane_field(pane, :window_name) || Map.get(window || %{}, :name) ||
          Map.get(window || %{}, "name") || window_id,
      display_name:
        pane_field(pane, :window_name) || Map.get(window || %{}, :name) ||
          Map.get(window || %{}, "name") || window_id,
      active?: truthy?(Map.get(window || %{}, :active) || Map.get(window || %{}, "active")),
      agent_state: pane_field(pane, :agent_state) || work_handle_status(pane, :state),
      agent_state_message:
        pane_field(pane, :agent_state_message) || work_handle_status(pane, :message),
      agent_state_resolution: pane_field(pane, :agent_state_resolution),
      agent_state_last_reported: pane_field(pane, :agent_state_last_reported),
      agent_state_reported_at: pane_field(pane, :agent_state_reported_at),
      agent_state_age_s: pane_field(pane, :agent_state_age_s),
      agent_pane_id: pane_field(pane, :id),
      label: pane_field(pane, :label),
      issue: pane_field(pane, :issue),
      issue_title: pane_field(pane, :issue_title),
      task_summary: pane_field(pane, :task_summary),
      fleet_role: pane_field(pane, :fleet_role) || Map.get(window || %{}, :fleet_role),
      fleet_readiness:
        pane_field(pane, :fleet_readiness) || Map.get(window || %{}, :fleet_readiness),
      ready_no_task_for_seconds:
        pane_field(pane, :ready_no_task_for_seconds) ||
          Map.get(window || %{}, :ready_no_task_for_seconds),
      liveness: pane_field(pane, :liveness),
      work_handle: pane_field(pane, :work_handle),
      quiet?: false,
      unseen_quiet?: false
    }
  end

  defp window_for(pane, %{windows: windows}) when is_list(windows) do
    wid = pane_field(pane, :window_id)

    Enum.find(windows, fn window ->
      (Map.get(window, :id) || Map.get(window, "id")) == wid
    end)
  end

  defp window_for(_, _), do: nil

  defp window_matches?(_pane, nil), do: true
  defp window_matches?(_pane, ""), do: true

  defp window_matches?(pane, window_id) when is_binary(window_id) do
    pane_field(pane, :window_id) == window_id
  end

  defp pane_field(nil, _key), do: nil

  defp pane_field(pane, key) when is_map(pane) do
    Map.get(pane, key) || Map.get(pane, Atom.to_string(key))
  end

  # Spell out what an absent `agent_state` means so a fail-closed reader does
  # not have to guess between "never reported" and "reported, then went quiet".
  defp agent_state_note(resolution, last_reported, age_s)
       when resolution in [:expired_report, "expired_report"] do
    "agent_state is not asserted: the last report (#{atom_or_nil(last_reported) || "unknown"}) " <>
      "is #{age_label(age_s)} old, past the assert window. Weigh agent_state_last_reported " <>
      "against liveness.quiet_for_seconds; a non-working last word over a worktree quiet " <>
      "as long is a worker that said it stopped, then stopped."
  end

  defp agent_state_note(resolution, _last_reported, _age_s)
       when resolution in [:unreported, "unreported"] do
    "agent_state is absent because this pane has never reported one (no hook or " <>
      "terminal_report_agent_state call reached Casein). Only liveness and the screen " <>
      "can speak for it."
  end

  defp agent_state_note(_resolution, _last_reported, _age_s), do: nil

  defp age_label(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"
  defp age_label(seconds) when is_integer(seconds) and seconds < 3600, do: "#{div(seconds, 60)}m"
  defp age_label(seconds) when is_integer(seconds), do: "#{div(seconds, 3600)}h"
  defp age_label(_seconds), do: "an unknown time"

  defp work_handle_status(pane, key) do
    with handle when is_map(handle) <- pane_field(pane, :work_handle),
         status when is_map(status) <- Map.get(handle, :status) || Map.get(handle, "status") do
      Map.get(status, key) || Map.get(status, Atom.to_string(key))
    else
      _ -> nil
    end
  end

  # GateQueue is irrelevant for single-worker projection; avoid host /proc scan.
  defp unknown_gate do
    %{
      lock_state: :unknown,
      depth: nil,
      waiter_count: nil,
      holder: nil,
      waiters: [],
      observed_at: nil,
      lock_path: nil,
      source: :skipped
    }
  end

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

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_or_nil(value) when is_binary(value), do: value
  defp atom_or_nil(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_), do: nil

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
