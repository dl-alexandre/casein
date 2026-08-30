defmodule Casein.Terminals.AgentState do
  @moduledoc """
  Semantic agent pane state, reported explicitly by agents (via Claude Code
  hooks or the `terminal_report_agent_state` MCP tool) and merged with the
  title-derived heuristic from `Casein.Terminals.PaneState`.

  States are `:working | :blocked | :done | :idle | :errored | :stalled |
  :awaiting_input | :unknown`, split by who is allowed to claim them:

    * **Report-only** — `:blocked`, `:done`, `:errored`. The title heuristic can
      never claim these. Claude's heavy-asterisk marker means "ready *or waiting
      for input*" (see `Casein.Terminals.PaneState`), so treating it as `:done`
      would render a blocked permission prompt as finished whenever hooks are
      absent.

    * **Derived-only** — `:stalled` and `:awaiting_input`. Never reported,
      because the agents that most need them are exactly the ones that have
      stopped reporting anything. See "Stale spinners" and "Ready or waiting"
      below.

    * **Screen-inferred** — a separately tagged, weakest fallback for hook-less
      OpenCode and Cursor panes. The screen classifier itself emits only
      `:permission_prompt | :working | :unknown`; `resolve_screen_fallback/3`
      may project those observations as `:blocked` / `:working` for display but
      always returns `:screen` provenance. It never replaces a report or a
      derived verdict, and no match remains `:unknown` (never `:idle`).

  ## Ready or waiting

  Claude's heavy-asterisk marker is ambiguous by construction: it means "ready
  **or** waiting for input". That ambiguity is why the title heuristic may not
  claim `:done`, and it leaves a real gap — a hook-less pane sitting on a
  question is indistinguishable from one that finished an hour ago. Both render
  as nothing.

  `Casein.Agents.Transcripts.Evidence` resolves it from outside the agent, by
  reading the shape of the last turn in the agent's own session transcript. An
  assistant prose turn followed by silence means the agent said its piece and
  stopped; nothing is outstanding on its side. That is `:awaiting_input`.

  Like `:stalled`, it claims only what is observed. It does not distinguish
  "asked you a question" from "finished and is idle" — the transcript looks the
  same either way, and a permission prompt is not written to it at all. It says
  the agent is not going to do anything else until a human acts.

  ### Why it outranks the other derived states

  `:stalled` and the missed-`Stop` fallback to `:idle` are both *inferences from
  absence*: nothing on disk, no fresh report. `:awaiting_input` is positive
  evidence from the conversation itself, so it replaces them where they would
  otherwise be reached. It never replaces a live report — an agent that says it
  is `:blocked` or `:errored` is making a claim about cause that no amount of
  transcript shape can refute.

  ## Stale spinners

  A wedged agent — one whose provider rejects every request, or whose TUI has
  stopped processing input — leaves its last spinner frame on screen. The title
  heuristic reads that frozen spinner as `:working` and, because a live title
  outranks a stale report, it used to overwrite every other signal indefinitely.
  A wedged window was therefore indistinguishable from a busy one, and a
  wedged-then-abandoned window looked identical to an idle one.

  `resolve/4` accepts an *externally observed* liveness verdict from
  `Casein.Terminals.AgentLiveness` (worktree writes and commits, which need no
  cooperation from the agent). When the title claims `:working` but nothing has
  happened on disk for `@stall_seconds`, the spinner is not believed and the
  state resolves to `:stalled`.

  `:stalled` deliberately does not claim the agent is *broken* — an agent can
  legitimately think for minutes without writing. It claims only what is
  observed: the pane looks busy and there is no external evidence of work.
  `:errored` remains a claim about cause, and so stays report-only.

  Entries are keyed by `{tmux_session, pane_id}`, held in an in-memory GenServer,
  and broadcast to workspace LiveViews. They never mutate tmux titles.

  ## Provenance travels with the state — and survives its absence

  A report older than `@max_report_ttl_seconds` is no longer *asserted* as
  `agent_state`, and a `:blocked` report past `@stale_assert_seconds` with no
  corroboration ages out to unknown. Both used to leave the pane looking exactly
  like one that had never reported at all, which is how a finished worker became
  "permanently unreapable" to a fail-closed gate (OneBackend-v3#20022): the one
  field the gate needed vanished precisely because the worker went quiet.

  `enrich_topology/2` therefore always attaches `agent_state_resolution`:

    * `:report` — a live report is being asserted
    * `:derived` — `:stalled` / `:awaiting_input`, inferred from evidence
    * `:expired_report` — a report exists but is too old to assert; look at
      `agent_state_last_reported` / `agent_state_reported_at` /
      `agent_state_age_s` and combine with liveness
    * `:unreported` — this pane has never reported (or nothing is retained)

  Only `:unreported` and a live `:working` are "cannot tell whether it is still
  working". An `:expired_report` whose last word was `done` / `blocked` / `idle`
  hours ago, over a worktree that has been quiet as long, is a worker that said
  it stopped and then stopped. The store also rehydrates the last durable
  transition per pane at boot (`Casein.Terminals.AgentState.Server`), so a
  canary deploy no longer erases that history.

  `resolve/3` is the pure precedence function that reconciles an explicit report
  against the live title heuristic; it is where staleness rules live and is unit
  tested directly.
  """

  alias Casein.Terminals.AgentState.Server
  alias Casein.Terminals.PaneState
  alias Phoenix.PubSub

  @topic_prefix "agent_state:"

  # Fresh reports win outright (absorbs transition flapping while the title
  # spinner catches up).
  @grace_seconds 10
  # A `working` report older than this, with the title showing `ready`, means the
  # agent almost certainly stopped and the hook missed the `Stop` event.
  @working_ttl_seconds 120
  # Past this, an uncorroborated report is no longer asserted. Topology reports
  # `:unknown` rather than the last known value — unknown never means idle.
  # Same window as `@working_ttl_seconds` so a ready title and a silent
  # worktree age out together. `agent_state_age_s` is this clock.
  @stale_assert_seconds 120
  # Beyond this a report is stale enough to discard entirely and fall back to the
  # title heuristic. Matches `Activity`'s attention window.
  @max_report_ttl_seconds 1_800
  # How long a pane may look busy with no observed worktree activity before its
  # spinner stops being believed. Generous on purpose: long tool calls and model
  # thinking time are normal, and a false `:stalled` costs operator trust.
  # Attention Delivery thresholds must not silently retune this (see #699).
  @stall_seconds 600
  # Notification hooks fire for startup banners as well as permission prompts.
  # These needles are never a blocked `agent_state_message`.
  @lifecycle_message_needles [
    "login successful",
    "logged in",
    "session start",
    "session started",
    "session end",
    "session ended"
  ]

  @report_states [:working, :blocked, :done, :idle, :errored]
  @screen_fallback_runtimes ~w(opencode cursor)

  @type state ::
          :working | :blocked | :done | :idle | :errored | :stalled | :awaiting_input | :unknown
  @type liveness :: :active | :quiet | :unknown | nil
  @type transcript :: :working | :awaiting_input | :unknown | nil
  @type screen_status :: :permission_prompt | :working | :unknown | nil
  @type provenance :: :report | :derived | :screen | :unknown
  @type resolution :: :report | :derived | :expired_report | :unreported
  @type entry :: %{
          state: state(),
          message: String.t() | nil,
          source: :mcp | :hook | :dispatch | :durable,
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
  Apply a screen observation as the third and weakest provenance.

  The input must already have been resolved from reports, liveness, and
  transcript evidence. Any known state wins unchanged. Screen evidence is
  accepted only for runtimes without a hook path, and its separate provenance
  prevents a permission-dialog observation from masquerading as report-only
  `:blocked` evidence.
  """
  @spec resolve_screen_fallback(
          {state(), String.t() | nil},
          String.t() | atom() | nil,
          screen_status()
        ) :: {state(), String.t() | nil, provenance()}
  def resolve_screen_fallback({state, message}, _runtime, _screen_status)
      when state in [
             :working,
             :blocked,
             :done,
             :idle,
             :errored,
             :stalled,
             :awaiting_input
           ] do
    {state, message, provenance_for(state)}
  end

  def resolve_screen_fallback({:unknown, _message}, runtime, screen_status) do
    if screen_fallback_runtime?(runtime) do
      case screen_status do
        :permission_prompt -> {:blocked, nil, :screen}
        :working -> {:working, nil, :screen}
        _ -> {:unknown, nil, :unknown}
      end
    else
      {:unknown, nil, :unknown}
    end
  end

  def resolve_screen_fallback(_resolved, _runtime, _screen_status),
    do: {:unknown, nil, :unknown}

  defp screen_fallback_runtime?(runtime) when is_atom(runtime),
    do: screen_fallback_runtime?(Atom.to_string(runtime))

  defp screen_fallback_runtime?(runtime) when is_binary(runtime),
    do: String.downcase(runtime) in @screen_fallback_runtimes

  defp screen_fallback_runtime?(_runtime), do: false

  defp provenance_for(state) when state in [:stalled, :awaiting_input], do: :derived
  defp provenance_for(state) when state in @report_states, do: :report

  @doc """
  Seconds of worktree quiet while a pane still looks busy before resolve yields
  `:stalled`. Inspectable constant — attention thresholds must not change this
  without an explicit product decision (#699).
  """
  @spec stall_seconds() :: pos_integer()
  def stall_seconds, do: @stall_seconds

  @doc """
  Seconds a report may be asserted without a corroborating signal before
  `resolve/5` yields `:unknown`. Inspectable so topology tests can pin the
  `agent_state_age_s` clock without re-deriving the threshold.
  """
  @spec stale_assert_seconds() :: pos_integer()
  def stale_assert_seconds, do: @stale_assert_seconds

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
    PubSub.subscribe(Casein.PubSub, topic(workspace_id))
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

  def resolve(entry, heuristic, now), do: resolve(entry, heuristic, now, nil)

  @doc """
  `resolve/3` with an externally observed liveness verdict.

  `liveness` is `:active | :quiet | :unknown | nil` — see
  `Casein.Terminals.AgentLiveness.classify/2`. `:unknown` and `nil` are treated
  identically and change nothing: a liveness check that could not run is not
  evidence of a stall, and inferring one from it is how false stall reports get
  made.
  """
  @spec resolve(entry() | nil, PaneState.state(), DateTime.t(), liveness()) ::
          {state(), String.t() | nil}
  def resolve(entry, heuristic, now, liveness), do: resolve(entry, heuristic, now, liveness, nil)

  @doc """
  `resolve/4` with a transcript-shape verdict from
  `Casein.Agents.Transcripts.Evidence.classify/2`.

  `transcript` is `:working | :awaiting_input | :unknown | nil`. As with
  `liveness`, `:unknown` and `nil` are treated identically and change nothing.
  `:awaiting_input` replaces the states that would otherwise be *inferred from
  absence* (`:stalled`, and the missed-`Stop` fallback to `:idle`), and never
  replaces a live report — see "Ready or waiting" in the module doc.
  """
  @spec resolve(entry() | nil, PaneState.state(), DateTime.t(), liveness(), transcript()) ::
          {state(), String.t() | nil}
  def resolve(nil, heuristic, _now, liveness, transcript) do
    case {semantic_from_heuristic(heuristic), liveness} do
      # An unreported pane whose spinner is frozen and whose worktree is silent.
      # Without this, an abandoned agent shows `:working` forever.
      {:working, :quiet} -> {derived(:stalled, transcript), nil}
      {state, _liveness} -> {derived(state, transcript), nil}
    end
  end

  def resolve(
        %{state: rstate, message: msg, reported_at: at},
        heuristic,
        now,
        liveness,
        transcript
      ) do
    age = DateTime.diff(now, at, :second)

    cond do
      age > @max_report_ttl_seconds ->
        resolve(nil, heuristic, now, liveness, transcript)

      # Startup/lifecycle Notification strings are not a human-attention claim.
      # Drop them before the grace window so a login banner never lands as
      # `:blocked` even for a few seconds.
      rstate == :blocked and lifecycle_message?(msg) ->
        uncorroborated(heuristic, now, liveness, transcript)

      age < @grace_seconds ->
        {rstate, msg}

      # A live title outranks a stale report — but only while the title is
      # believable. A frozen spinner over a silent worktree is the wedge
      # signature, and promoting it to `:working` is what made a wedged window
      # indistinguishable from a busy one.
      heuristic == :working and rstate != :working ->
        if liveness == :quiet and age > @stall_seconds,
          do: {derived(:stalled, transcript), nil},
          else: {derived(:working, transcript), nil}

      # The agent claims to be working and the title agrees, but nothing has
      # touched the worktree. Believe the evidence over both.
      heuristic == :working and rstate == :working and liveness == :quiet and
          age > @stall_seconds ->
        {derived(:stalled, transcript), nil}

      # The hook probably missed a `Stop` event... unless the worktree says the
      # agent is still writing, in which case the report was right and the title
      # is merely between spinner frames.
      heuristic == :ready and rstate == :working and age > @working_ttl_seconds ->
        if liveness == :active, do: {:working, msg}, else: {derived(:idle, transcript), nil}

      # blocked + ready (or any non-working title) past the assert window, with
      # no active worktree: stop asserting the last known value. Unknown never
      # means idle — a pane at an empty prompt is not `:blocked`.
      rstate == :blocked and age > @stale_assert_seconds and
          not corroborated_block?(heuristic, liveness) ->
        {:unknown, nil}

      true ->
        {rstate, msg}
    end
  end

  # Applied only where the state being returned was inferred rather than
  # reported. `:unknown` is included because a pane whose title we cannot read
  # is exactly the hook-less case this evidence exists for — but the caller only
  # attaches transcript evidence to agent panes, so a plain shell never lands
  # here with a verdict.
  defp derived(state, :awaiting_input) when state in [:stalled, :working, :idle, :unknown],
    do: :awaiting_input

  defp derived(state, _transcript), do: state

  # A discarded blocked claim must not become `:idle` via the title heuristic —
  # unknown never means idle. Keep only positive observations (spinner, stall,
  # transcript waiting).
  defp uncorroborated(heuristic, now, liveness, transcript) do
    case resolve(nil, heuristic, now, liveness, transcript) do
      {:stalled, message} -> {:stalled, message}
      {:awaiting_input, message} -> {:awaiting_input, message}
      {:working, message} -> {:working, message}
      _other -> {:unknown, nil}
    end
  end

  defp corroborated_block?(:working, _liveness), do: true
  defp corroborated_block?(_heuristic, :active), do: true
  defp corroborated_block?(_heuristic, _liveness), do: false

  defp lifecycle_message?(message) when is_binary(message) do
    down = String.downcase(message)
    Enum.any?(@lifecycle_message_needles, &String.contains?(down, &1))
  end

  defp lifecycle_message?(_message), do: false

  @doc """
  Like `resolve/3`, but returns `{:unknown, nil}` when there is no live report
  (nil, or older than the max TTL). Use this for UI enrichment so panes/windows
  without a real report fall back to the title heuristic instead of being labeled
  from it (e.g. a plain shell showing `ready` must not read as an idle agent).
  """
  @spec resolve_for_display(entry() | nil, PaneState.state(), DateTime.t(), liveness()) ::
          {state(), String.t() | nil}
  def resolve_for_display(entry, heuristic, now \\ DateTime.utc_now(), liveness \\ nil)

  def resolve_for_display(entry, heuristic, now, liveness),
    do: resolve_for_display(entry, heuristic, now, liveness, nil)

  @doc "`resolve_for_display/4` with a transcript-shape verdict."
  @spec resolve_for_display(
          entry() | nil,
          PaneState.state(),
          DateTime.t(),
          liveness(),
          transcript()
        ) :: {state(), String.t() | nil}
  # A pane with no report is normally left unlabeled, so a plain shell showing
  # `ready` does not read as an idle agent. Two exceptions are worth naming: a
  # frozen spinner over a silent worktree is displaying activity that is not
  # happening, and an agent that stopped talking is waiting on a human. Saying
  # nothing lets the first lie stand and leaves the second unanswered.
  def resolve_for_display(nil, heuristic, now, liveness, transcript) do
    case resolve(nil, heuristic, now, liveness, transcript) do
      {:stalled, message} -> {:stalled, message}
      {:awaiting_input, message} -> {:awaiting_input, message}
      _other -> {:unknown, nil}
    end
  end

  def resolve_for_display(%{reported_at: at} = entry, heuristic, now, liveness, transcript) do
    if DateTime.diff(now, at, :second) > @max_report_ttl_seconds do
      resolve_for_display(nil, heuristic, now, liveness, transcript)
    else
      resolve(entry, heuristic, now, liveness, transcript)
    end
  end

  @doc """
  Enrich a topology map with resolved `:agent_state` / `:agent_state_message` on
  every pane and window. Runs after `PaneState.enrich_topology/1` so panes and
  windows already carry the title heuristic in `:pane_state`. Only panes/windows
  with a live report are labeled (see `resolve_for_display/4`).

  When `Casein.Terminals.PaneLiveness` has already attached `:liveness` to the
  panes, its verdict is folded in so a frozen spinner over a silent worktree
  resolves to `:stalled` instead of `:working`. Without it the behaviour is
  unchanged, so callers that cannot afford a worktree walk lose nothing.
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
        age_s = report_age_s(entry, now)

        resolved =
          entry
          |> resolve_for_display(heuristic, now, pane_liveness(pane), pane_transcript(pane))
          |> age_out_with(age_s, heuristic, pane_liveness(pane))

        window
        |> put_report_age(age_s)
        |> put_state(resolved)
        |> put_report_meta(entry, resolved)
        |> put_blocked_ready_conflict(resolved, heuristic)
        |> put_agent_session_id(entry, resolved)
        |> put_transcript_path(entry, resolved)
      end)

    %{topology | panes: panes, windows: windows}
  end

  def enrich_topology(topology, _tmux_session), do: topology

  defp enrich_pane(pane, reports, now) when is_map(pane) do
    heuristic = normalize_heuristic(PaneState.map_get(pane, :pane_state))
    entry = Map.get(reports, PaneState.map_get(pane, :id))
    age_s = report_age_s(entry, now)
    liveness = pane_liveness(pane)

    resolved =
      entry
      |> resolve_for_display(heuristic, now, liveness, pane_transcript(pane))
      |> age_out_with(age_s, heuristic, liveness)

    pane
    |> put_report_age(age_s)
    |> put_state(resolved)
    |> put_report_meta(entry, resolved)
    |> put_blocked_ready_conflict(resolved, heuristic)
    |> put_agent_session_id(entry, resolved)
    |> put_transcript_path(entry, resolved)
  end

  defp enrich_pane(pane, _reports, _now), do: pane

  defp report_age_s(%{reported_at: %DateTime{} = at}, now),
    do: max(DateTime.diff(now, at, :second), 0)

  defp report_age_s(_entry, _now), do: nil

  defp put_report_age(map, age_s) when is_integer(age_s),
    do: Map.put(map, :agent_state_age_s, age_s)

  defp put_report_age(map, _age_s), do: map

  # The classifier reads `agent_state_age_s` (same clock as resolve/5) so a
  # topology that already carries the age cannot keep asserting a stale
  # `:blocked` over a ready title.
  defp age_out_with({:blocked, _message} = resolved, age_s, heuristic, liveness)
       when is_integer(age_s) and age_s > @stale_assert_seconds do
    if corroborated_block?(heuristic, liveness), do: resolved, else: {:unknown, nil}
  end

  defp age_out_with(resolved, _age_s, _heuristic, _liveness), do: resolved

  # blocked + ready on the same pane is a conflict. Recency is the only
  # qualification that lets the report stand; surface it so consumers do not
  # treat the pair as unqualified.
  defp put_blocked_ready_conflict(map, {:blocked, _message}, :ready),
    do: Map.put(map, :agent_state_conflict, :blocked_while_ready)

  defp put_blocked_ready_conflict(map, _resolved, _heuristic), do: map

  @doc """
  Why `agent_state` says what it says (or is absent) — see the module doc.
  Pure over the stored entry and the resolved `{state, message}`.
  """
  @spec resolution_for(entry() | nil, {state(), String.t() | nil}) :: resolution()
  def resolution_for(_entry, {state, _message}) when state in [:stalled, :awaiting_input],
    do: :derived

  def resolution_for(nil, _resolved), do: :unreported
  def resolution_for(%{}, {:unknown, _message}), do: :expired_report
  def resolution_for(%{}, _resolved), do: :report

  # Provenance and the last report are attached whether or not the state is
  # asserted: "last said blocked 6h ago" is evidence a caller can weigh, and
  # "never reported" is a different condition from "expired" (#20022).
  defp put_report_meta(map, entry, resolved) do
    map
    |> Map.put(:agent_state_resolution, resolution_for(entry, resolved))
    |> put_last_report(entry)
  end

  defp put_last_report(map, %{state: state, reported_at: %DateTime{} = at} = entry) do
    map
    |> Map.put(:agent_state_last_reported, state)
    |> Map.put(:agent_state_reported_at, DateTime.to_iso8601(at))
    |> Map.put(:agent_state_report_source, Map.get(entry, :source))
  end

  defp put_last_report(map, _entry), do: map

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

  defp put_transcript_path(
         map,
         %{transcript_path: transcript_path},
         {state, _message}
       )
       when is_binary(transcript_path) and transcript_path != "" and state != :unknown,
       do: Map.put(map, :transcript_path, transcript_path)

  defp put_transcript_path(map, _entry, _resolved), do: map

  # `PaneLiveness` attaches `:liveness` only when a worktree was actually
  # observed. Anything else — absent, unknown, unreadable — must stay nil so
  # `resolve/4` treats it as "no evidence" rather than "no activity".
  #
  # The verdict is re-derived against `@stall_seconds` rather than reusing
  # `liveness.state`, because the two thresholds answer different questions.
  # `PaneLiveness` classifies against a short activity window (is this agent
  # doing something *right now*), while a stall claim needs a much longer
  # silence to be worth making. Reusing the short verdict would mark an agent
  # that wrote four minutes ago as stalled — a false positive of exactly the
  # kind these states exist to eliminate.
  defp pane_liveness(pane) when is_map(pane) do
    case PaneState.map_get(pane, :liveness) do
      %{quiet_for_seconds: quiet_for} when is_integer(quiet_for) ->
        if quiet_for > @stall_seconds, do: :quiet, else: :active

      _ ->
        nil
    end
  end

  defp pane_liveness(_pane), do: nil

  # `Casein.Terminals.PaneLiveness` attaches `:transcript` only for agent panes
  # whose transcript it could unambiguously resolve. Anything else stays nil so
  # `resolve/5` treats it as "no evidence" — in particular a plain shell sitting
  # in an agent's worktree must never inherit that agent's conversation.
  defp pane_transcript(pane) when is_map(pane) do
    case PaneState.map_get(pane, :transcript) do
      %{state: state} when state in [:working, :awaiting_input] -> state
      _ -> nil
    end
  end

  defp pane_transcript(_pane), do: nil

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
  # Both need a human: one has failed, the other is displaying work it is not
  # doing. Neither is something the fleet will resolve on its own.
  defp picker_status(:errored), do: "attention"
  defp picker_status(:stalled), do: "attention"
  # The whole point of deriving it: this pane will not move until a human acts.
  defp picker_status(:awaiting_input), do: "attention"
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
