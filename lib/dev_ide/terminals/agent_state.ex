defmodule DevIDE.Terminals.AgentState do
  @moduledoc """
  Semantic agent pane state, reported explicitly by agents (via Claude Code
  hooks or the `terminal_report_agent_state` MCP tool) and merged with the
  title-derived heuristic from `DevIDE.Terminals.PaneState`.

  States are `:working | :blocked | :done | :idle | :unknown`. `:blocked` and
  `:done` are **report-only** — the title heuristic can never claim them. Claude's
  heavy-asterisk marker means "ready *or waiting for input*" (see
  `DevIDE.Terminals.PaneState`), so treating it as `:done` would render a blocked
  permission prompt as finished whenever hooks are absent.

  Entries are keyed by `{tmux_session, pane_id}`, held in an in-memory GenServer,
  and broadcast to workspace LiveViews. They never mutate tmux titles.

  `resolve/3` is the pure precedence function that reconciles an explicit report
  against the live title heuristic; it is where staleness rules live and is unit
  tested directly.
  """

  alias DevIDE.Terminals.AgentState.Server
  alias DevIDE.Terminals.PaneState
  alias Phoenix.PubSub

  @topic_prefix "agent_state:"

  # Fresh reports win outright (absorbs transition flapping while the title
  # spinner catches up).
  @grace_seconds 10
  # A `working` report older than this, with the title showing `ready`, means the
  # agent almost certainly stopped and the hook missed the `Stop` event.
  @working_ttl_seconds 120
  # Beyond this a report is stale enough to discard entirely and fall back to the
  # title heuristic. Matches `Activity`'s attention window.
  @max_report_ttl_seconds 1_800

  @report_states [:working, :blocked, :done, :idle]

  @type state :: :working | :blocked | :done | :idle | :unknown
  @type entry :: %{
          state: state(),
          message: String.t() | nil,
          source: :mcp | :hook | :dispatch,
          tool: String.t() | nil,
          workspace_id: String.t() | nil,
          transcript_path: String.t() | nil,
          agent_session_id: String.t() | nil,
          reported_at: DateTime.t()
        }

  @message_limit 200

  def start_link(opts \\ []), do: Server.start_link(opts)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The reportable semantic states, as atoms."
  @spec report_states() :: [state()]
  def report_states, do: @report_states

  @doc """
  Record an explicit semantic-state report for a pane.

  `state` may be an atom or string; unrecognized values are ignored (no-op).
  """
  @spec report(
          String.t() | nil,
          String.t(),
          String.t(),
          state() | String.t(),
          String.t() | nil,
          keyword()
        ) ::
          :ok
  def report(workspace_id, tmux_session, pane_id, state, message \\ nil, opts \\ [])
      when is_binary(tmux_session) and is_binary(pane_id) do
    case normalize_report_state(state) do
      nil ->
        :ok

      normalized ->
        Server.report(
          workspace_id,
          tmux_session,
          pane_id,
          normalized,
          truncate_message(message),
          Keyword.get(opts, :source, :mcp),
          Keyword.get(opts, :tool),
          normalize_transcript_path(Keyword.get(opts, :transcript_path)),
          normalize_agent_session_id(Keyword.get(opts, :agent_session_id))
        )
    end
  end

  @doc "Fetch the stored report entry for a pane, or nil."
  @spec get(String.t(), String.t()) :: entry() | nil
  def get(tmux_session, pane_id) when is_binary(tmux_session) and is_binary(pane_id) do
    Server.get(tmux_session, pane_id)
  end

  @doc "Report entries for every pane in a session, keyed by pane id."
  @spec for_session(String.t()) :: %{optional(String.t()) => entry()}
  def for_session(tmux_session) when is_binary(tmux_session) do
    Server.for_session(tmux_session)
  end

  @doc """
  The freshest non-expired reported state for a session, as a string suited to
  the workspace picker (`"running" | "attention" | "done" | "noop"`), or nil when
  there is no live report. Used by `SessionSummary` so an explicit report is not
  clobbered by generic MCP activity.
  """
  @spec session_status(String.t(), DateTime.t()) :: String.t() | nil
  def session_status(tmux_session, now \\ DateTime.utc_now()) when is_binary(tmux_session) do
    case Server.freshest(tmux_session, now, @max_report_ttl_seconds) do
      nil -> nil
      state -> picker_status(state)
    end
  end

  @doc "Prune report entries for panes that no longer exist in a session."
  @spec prune_session(String.t(), [String.t()]) :: :ok
  def prune_session(tmux_session, pane_ids) when is_binary(tmux_session) and is_list(pane_ids) do
    Server.prune_session(tmux_session, pane_ids)
  end

  @doc false
  @spec clear() :: :ok
  def clear, do: Server.clear()

  @spec subscribe(String.t()) :: :ok
  def subscribe(workspace_id) when is_binary(workspace_id) do
    PubSub.subscribe(DevIDE.PubSub, topic(workspace_id))
  end

  @doc false
  def topic(workspace_id), do: @topic_prefix <> workspace_id

  @doc "Map a title-heuristic `PaneState` value onto the semantic taxonomy."
  @spec semantic_from_heuristic(PaneState.state()) :: state()
  def semantic_from_heuristic(:working), do: :working
  def semantic_from_heuristic(:ready), do: :idle
  def semantic_from_heuristic(_), do: :unknown

  @doc """
  Reconcile an explicit report against the title heuristic, returning
  `{state, message | nil}`. `heuristic` is the raw `PaneState` value
  (`:working | :ready | :unknown`). See the module doc for the ordered rules.
  """
  @spec resolve(entry() | nil, PaneState.state(), DateTime.t()) :: {state(), String.t() | nil}
  def resolve(entry, heuristic, now \\ DateTime.utc_now())

  def resolve(nil, heuristic, _now), do: {semantic_from_heuristic(heuristic), nil}

  def resolve(%{state: rstate, message: msg, reported_at: at}, heuristic, now) do
    age = DateTime.diff(now, at, :second)

    cond do
      age > @max_report_ttl_seconds ->
        {semantic_from_heuristic(heuristic), nil}

      age < @grace_seconds ->
        {rstate, msg}

      heuristic == :working and rstate != :working ->
        {:working, nil}

      heuristic == :ready and rstate == :working and age > @working_ttl_seconds ->
        {:idle, nil}

      true ->
        {rstate, msg}
    end
  end

  @doc """
  Like `resolve/3`, but returns `{:unknown, nil}` when there is no live report
  (nil, or older than the max TTL). Use this for UI enrichment so panes/windows
  without a real report fall back to the title heuristic instead of being labeled
  from it (e.g. a plain shell showing `ready` must not read as an idle agent).
  """
  @spec resolve_for_display(entry() | nil, PaneState.state(), DateTime.t()) ::
          {state(), String.t() | nil}
  def resolve_for_display(entry, heuristic, now \\ DateTime.utc_now())

  def resolve_for_display(nil, _heuristic, _now), do: {:unknown, nil}

  def resolve_for_display(%{reported_at: at} = entry, heuristic, now) do
    if DateTime.diff(now, at, :second) > @max_report_ttl_seconds do
      {:unknown, nil}
    else
      resolve(entry, heuristic, now)
    end
  end

  @doc """
  Enrich a topology map with resolved `:agent_state` / `:agent_state_message` on
  every pane and window. Runs after `PaneState.enrich_topology/1` so panes and
  windows already carry the title heuristic in `:pane_state`. Only panes/windows
  with a live report are labeled (see `resolve_for_display/3`).
  """
  @spec enrich_topology(map(), String.t()) :: map()
  def enrich_topology(%{panes: panes, windows: windows} = topology, tmux_session)
      when is_list(panes) and is_list(windows) and is_binary(tmux_session) do
    reports = for_session(tmux_session)
    now = DateTime.utc_now()

    panes = Enum.map(panes, &enrich_pane(&1, reports, now))

    windows =
      Enum.map(windows, fn window ->
        heuristic = PaneState.window_state(window)
        pane = PaneState.agent_or_active_pane(window)
        entry = pane && Map.get(reports, PaneState.map_get(pane, :id))
        resolved = resolve_for_display(entry, heuristic, now)

        window
        |> put_state(resolved)
        |> put_agent_session_id(entry, resolved)
      end)

    %{topology | panes: panes, windows: windows}
  end

  def enrich_topology(topology, _tmux_session), do: topology

  defp enrich_pane(pane, reports, now) when is_map(pane) do
    heuristic = normalize_heuristic(PaneState.map_get(pane, :pane_state))
    entry = Map.get(reports, PaneState.map_get(pane, :id))
    resolved = resolve_for_display(entry, heuristic, now)

    pane
    |> put_state(resolved)
    |> put_agent_session_id(entry, resolved)
  end

  defp enrich_pane(pane, _reports, _now), do: pane

  # Omit `:unknown` so payloads and stable hashes stay compact when nothing is
  # known about a pane/window.
  defp put_state(map, {:unknown, _message}), do: map

  defp put_state(map, {state, message}) do
    map
    |> Map.put(:agent_state, state)
    |> put_message(message)
  end

  defp put_message(map, message) when is_binary(message) and message != "",
    do: Map.put(map, :agent_state_message, message)

  defp put_message(map, _message), do: map

  defp put_agent_session_id(
         map,
         %{agent_session_id: agent_session_id},
         {state, _message}
       )
       when is_binary(agent_session_id) and agent_session_id != "" and state != :unknown,
       do: Map.put(map, :agent_session_id, agent_session_id)

  defp put_agent_session_id(map, _entry, _resolved), do: map

  defp normalize_heuristic(:working), do: :working
  defp normalize_heuristic(:ready), do: :ready
  defp normalize_heuristic("working"), do: :working
  defp normalize_heuristic("ready"), do: :ready
  defp normalize_heuristic(_), do: :unknown

  defp normalize_report_state(state) when state in @report_states, do: state
  defp normalize_report_state("working"), do: :working
  defp normalize_report_state("blocked"), do: :blocked
  defp normalize_report_state("done"), do: :done
  defp normalize_report_state("idle"), do: :idle
  defp normalize_report_state(_), do: nil

  defp picker_status(:working), do: "running"
  defp picker_status(:blocked), do: "attention"
  defp picker_status(:done), do: "done"
  defp picker_status(:idle), do: "noop"
  defp picker_status(_), do: nil

  defp truncate_message(message) when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @message_limit)
    end
  end

  defp truncate_message(_message), do: nil

  defp normalize_transcript_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_transcript_path(_path), do: nil

  defp normalize_agent_session_id(session_id) when is_binary(session_id) do
    case String.trim(session_id) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @message_limit)
    end
  end

  defp normalize_agent_session_id(_session_id), do: nil
end
