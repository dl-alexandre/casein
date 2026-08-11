defmodule Casein.Terminals.FleetSummary do
  @moduledoc """
  Read-only fleet picture for the `casein://fleet/summary` MCP resource (#859).

  One call replaces `terminal_topology` + N `terminal_capture` scrapes for
  "what is my fleet doing?". Per pane it returns runtime, worktree, branch,
  whether the branch has commits not on origin, and a **process/CPU** liveness
  signal (`Casein.Terminals.PaneProcessLiveness`) — never the rendered spinner.

  Process/CPU answers "is the pane process still running?", not "is the agent
  making progress?". Composite progress (context/spend/worktree/screen deltas,
  running-but-not-progressing) is #879 and out of scope here.

  Pure projection over existing session/topology enrichment plus process
  sampling. No mutation verbs, no scrollback.
  """

  alias Casein.Agents.TerminalTools.Impl.Shared
  alias Casein.Git.Inspector
  alias Casein.Labels
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.FleetChrome
  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.NextPrompt
  alias Casein.Terminals.PaneLiveness
  alias Casein.Terminals.PaneProcessLiveness
  alias Casein.Terminals.PaneState
  alias Casein.Terminals.TmuxTopology

  @resource_uri "casein://fleet/summary"
  @mime "application/json"

  @type payload :: %{
          uri: String.t(),
          workspace_id: String.t() | nil,
          generated_at: String.t(),
          session_count: non_neg_integer(),
          pane_count: non_neg_integer(),
          sessions: [map()],
          note: String.t()
        }

  @doc "Canonical MCP resource URI."
  @spec resource_uri() :: String.t()
  def resource_uri, do: @resource_uri

  @doc "Resource descriptor for `resources/list`."
  @spec resource_descriptor() :: map()
  def resource_descriptor do
    %{
      uri: @resource_uri,
      name: "Fleet summary",
      description:
        "Read-only fleet picture: sessions, panes, runtime, worktree, branch, " <>
          "commits-not-on-origin, and process/CPU liveness in one call. " <>
          "Liveness is process presence from cumulative CPU jiffies on the pane " <>
          "process tree — never the rendered spinner. CPU alone does not prove " <>
          "agent progress (see #879).",
      mimeType: @mime
    }
  end

  @doc """
  Build the fleet summary for a workspace (or every casein session when unscoped).

  Options:

    * `:workspace_id` — scope sessions (required for pre-scoped MCP)
    * `:now` — `DateTime` for `generated_at`
    * `:tmux` — topology adapter override
    * `:process_liveness_opts` — forwarded to `PaneProcessLiveness.observe_session/2`
    * `:git` — set `false` to skip branch/ahead inspection
  """
  @spec build(keyword()) :: payload()
  def build(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    sessions =
      opts
      |> session_metas()
      |> Enum.map(&summarize_session(&1, opts))

    panes = Enum.flat_map(sessions, & &1.panes)

    %{
      uri: @resource_uri,
      workspace_id: workspace_id,
      generated_at: DateTime.to_iso8601(now),
      session_count: length(sessions),
      pane_count: length(panes),
      sessions: sessions,
      note:
        "Read-only fleet summary (#859). Liveness is process/CPU presence " <>
          "(PaneProcessLiveness cumulative jiffies), not the rendered spinner — " <>
          "necessary-not-sufficient; CPU alone ≠ agent progress (#879). " <>
          "branch/ahead come from Git.Inspector per worktree. No mutations."
    }
  end

  # `:sessions` lets unit tests inject metas without Workspaces/Manager I/O.
  # Production path lists casein_* sessions via the configured tmux adapter.
  defp session_metas(opts) do
    case Keyword.get(opts, :sessions) do
      list when is_list(list) ->
        list

      _ ->
        workspace_id = Keyword.get(opts, :workspace_id)
        params = if is_binary(workspace_id), do: %{"workspace_id" => workspace_id}, else: %{}
        list_casein_sessions(params, opts)
    end
  end

  defp list_casein_sessions(params, opts) do
    adapter = Keyword.get(opts, :tmux) || Shared.tmux()

    adapter.list_sessions()
    |> Enum.flat_map(&normalize_session_meta/1)
    |> Enum.filter(&String.starts_with?(&1.session, "casein_"))
    |> filter_by_workspace(params)
  rescue
    _ -> []
  end

  defp normalize_session_meta(%{session: name} = meta) when is_binary(name), do: [meta]

  defp normalize_session_meta(%{"session" => name} = meta) when is_binary(name),
    do: [Map.new(meta, fn {k, v} -> {string_to_atom_key(k), v} end)]

  defp normalize_session_meta(name) when is_binary(name), do: [%{session: name}]
  defp normalize_session_meta(_), do: []

  defp filter_by_workspace(sessions, params) do
    case Shared.workspace_id(params) do
      nil ->
        sessions

      _id ->
        # Prefer Shared's exact namespace filter when it works; fall back to
        # the raw list on Workspaces/Manager failure so the resource stays up.
        try do
          Shared.filter_workspace(sessions, params)
        rescue
          _ -> sessions
        end
    end
  end

  @doc "JSON-encode the payload for `resources/read` text contents."
  @spec to_json(payload()) :: String.t()
  def to_json(payload) when is_map(payload) do
    payload
    |> jsonable()
    |> Jason.encode!()
  end

  ## Session / pane projection

  defp summarize_session(%{session: session_name} = session_meta, opts) do
    topology = enriched_topology(session_name, opts)
    proc_by_pane = PaneProcessLiveness.observe_session(session_name, process_opts(opts))
    panes = Enum.map(topology.panes || [], &pane_json(&1, topology, proc_by_pane, opts))

    %{
      session: session_name,
      attached: Map.get(session_meta, :attached),
      activity: Map.get(session_meta, :activity),
      active_window_id: Map.get(topology, :active_window_id),
      active_pane_id: Map.get(topology, :active_pane_id),
      window_count: length(Map.get(topology, :windows) || []),
      pane_count: length(panes),
      panes: panes
    }
    |> reject_nil()
  end

  defp summarize_session(%{"session" => _} = session_meta, opts) do
    summarize_session(Map.new(session_meta, fn {k, v} -> {string_to_atom_key(k), v} end), opts)
  end

  defp summarize_session(_, _), do: %{session: nil, panes: [], pane_count: 0, window_count: 0}

  defp string_to_atom_key(k) when is_atom(k), do: k
  defp string_to_atom_key("session"), do: :session
  defp string_to_atom_key("attached"), do: :attached
  defp string_to_atom_key("activity"), do: :activity
  defp string_to_atom_key(k) when is_binary(k), do: String.to_existing_atom(k)

  defp enriched_topology(session, opts) do
    tmux = Keyword.get(opts, :tmux)
    snap_opts = if tmux, do: [tmux: tmux], else: []

    snapshot =
      try do
        TmuxTopology.snapshot(session, snap_opts)
      rescue
        _ -> empty_topology(session)
      end

    # Worktree join always on; disk-walk liveness stays off — process/CPU is the
    # fleet-summary signal (issue #859). Labels/issue/agent_state still help
    # operators scan without capture.
    snapshot
    |> PaneLiveness.enrich_topology(liveness: false, transcript: false)
    |> safe_enrich(&AgentState.enrich_topology(&1, session))
    |> safe_enrich(&NextPrompt.enrich_topology(&1, session))
    |> safe_enrich(&IssueBinding.enrich_topology(&1, session))
    |> safe_enrich(&Labels.enrich_topology(&1, session))
    |> put_window_names_on_panes()
    |> FleetChrome.enrich_topology()
  end

  defp safe_enrich(topology, fun) do
    fun.(topology)
  rescue
    _ -> topology
  end

  defp empty_topology(session) do
    %{
      session: session,
      windows: [],
      panes: [],
      active_window_id: nil,
      active_pane_id: nil,
      version: 0,
      structure_version: 0,
      layout_version: 0
    }
  end

  defp process_opts(opts) do
    Keyword.get(opts, :process_liveness_opts, [])
  end

  defp pane_json(pane, topology, proc_by_pane, opts) do
    pane_id = PaneState.map_get(pane, :id)
    proc = Map.get(proc_by_pane, pane_id) || %{}
    worktree = PaneState.map_get(pane, :worktree_path)
    git = git_facts(worktree, opts)
    window = window_for(pane, topology)

    runtime =
      PaneState.map_get(pane, :agent_runtime) ||
        Map.get(proc, :runtime) ||
        PaneProcessLiveness.runtime_from_command(PaneState.map_get(pane, :current_command))

    %{
      pane_id: pane_id,
      window_id: PaneState.map_get(pane, :window_id) || Map.get(window || %{}, :id),
      window_name: PaneState.map_get(pane, :window_name) || Map.get(window || %{}, :name),
      role: stringify(PaneState.map_get(pane, :role)),
      active?: truthy?(PaneState.map_get(pane, :active)),
      current_command:
        Map.get(proc, :current_command) || PaneState.map_get(pane, :current_command),
      runtime: runtime,
      agent_state: stringify(PaneState.map_get(pane, :agent_state)),
      agent_state_message: PaneState.map_get(pane, :agent_state_message),
      label: PaneState.map_get(pane, :label),
      issue: PaneState.map_get(pane, :issue),
      issue_title: PaneState.map_get(pane, :issue_title),
      task_summary: PaneState.map_get(pane, :task_summary),
      fleet_role: stringify(PaneState.map_get(pane, :fleet_role)),
      fleet_readiness: stringify(PaneState.map_get(pane, :fleet_readiness)),
      ready_no_task_for_seconds: PaneState.map_get(pane, :ready_no_task_for_seconds),
      worktree_path: worktree,
      branch: Map.get(git, :branch),
      head_sha: Map.get(git, :head_sha),
      upstream: Map.get(git, :upstream),
      ahead: Map.get(git, :ahead),
      behind: Map.get(git, :behind),
      commits_not_on_origin?: Map.get(git, :commits_not_on_origin?),
      detached?: Map.get(git, :detached?),
      liveness: liveness_json(proc)
    }
    |> reject_nil()
  end

  defp liveness_json(%{state: state} = proc) do
    %{
      state: stringify(state),
      source: "process_cpu",
      reason: stringify(Map.get(proc, :reason)),
      pid: Map.get(proc, :pid),
      tree_pid_count: length(Map.get(proc, :tree_pids) || []),
      cpu_jiffies: Map.get(proc, :cpu_jiffies),
      cpu_jiffies_delta: Map.get(proc, :cpu_jiffies_delta),
      sample_age_ms: Map.get(proc, :sample_age_ms)
    }
    |> reject_nil()
  end

  defp liveness_json(_) do
    %{state: "unknown", source: "process_cpu", reason: "no_sample"}
  end

  defp git_facts(path, opts) when is_binary(path) and path != "" do
    if Keyword.get(opts, :git, true) == false do
      %{}
    else
      case Inspector.inspect_cwd(path) do
        {:ok, info} ->
          ahead = info.ahead

          %{
            branch: info.branch,
            head_sha: info.head_sha,
            upstream: info.upstream,
            ahead: ahead,
            behind: info.behind,
            detached?: info.detached?,
            commits_not_on_origin?: is_integer(ahead) and ahead > 0
          }

        :error ->
          %{commits_not_on_origin?: nil}
      end
    end
  end

  defp git_facts(_, _), do: %{}

  defp window_for(pane, %{windows: windows}) when is_list(windows) do
    wid = PaneState.map_get(pane, :window_id)

    Enum.find(windows, fn w ->
      (Map.get(w, :id) || Map.get(w, "id")) == wid
    end)
  end

  defp window_for(_, _), do: nil

  defp put_window_names_on_panes(%{panes: panes, windows: windows} = topology)
       when is_list(panes) and is_list(windows) do
    names =
      Map.new(windows, fn w ->
        {Map.get(w, :id) || Map.get(w, "id"), Map.get(w, :name) || Map.get(w, "name")}
      end)

    panes =
      Enum.map(panes, fn pane ->
        case Map.get(names, PaneState.map_get(pane, :window_id)) do
          name when is_binary(name) -> Map.put(pane, :window_name, name)
          _ -> pane
        end
      end)

    %{topology | panes: panes}
  end

  defp put_window_names_on_panes(topology), do: topology

  defp stringify(nil), do: nil
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)

  defp truthy?(v), do: v in [true, "true", "1", 1]

  defp reject_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp jsonable(value) when is_struct(value), do: jsonable(Map.from_struct(value))

  defp jsonable(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {jsonable_key(k), jsonable(v)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(other), do: other

  defp jsonable_key(k) when is_atom(k), do: Atom.to_string(k)
  defp jsonable_key(k) when is_binary(k), do: k
  defp jsonable_key(k), do: to_string(k)
end
