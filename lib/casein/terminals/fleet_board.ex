defmodule Casein.Terminals.FleetBoard do
  @moduledoc """
  Operator-visible **fleet aggregate** over per-window agent chrome.

  Per-pane signals already exist (`AgentState`, `AgentLiveness` / `PaneLiveness`,
  `IssueBinding`, `FleetChrome`). This module does not own state and does not
  invent a second classifier — it projects already-resolved window tabs into:

    * bucket counts (`needs_you`, `working`, `ready_no_task`, `idle`, `done`,
      `unknown`)
    * sorted rows an operator can scan for "what are my N workers doing?"
    * an attention count for cockpit badge chrome

  ## Kind discipline

  Report-only (`:blocked`, `:errored`) and derived-only (`:stalled`,
  `:awaiting_input`) stay distinct on each row.

  ## Unknown vs quiet vs idle (#916)

  `:unknown` is reserved for **could not classify** — not a synonym for quiet.
  A worker row with no cooperative agent_state report (common for OpenCode /
  hook-less panes) is still classifiable from external liveness:

    * liveness `:active` → bucket `:working` (process/worktree evidence)
    * liveness `:quiet` → bucket `:idle` (observed quiet, not a missing signal)
    * liveness `:unknown` or missing → bucket `:unknown` **with**
      `unknown_reason` explaining why (never a bare unknown)

  Collapsing unscanned/unknown liveness into idle is forbidden — that is the
  #910 distinction this board exists to protect.

  ## Attention model

  `needs_you?` means **a human is blocking the work**, and nothing else. Only
  report-kind `:blocked` / `:errored` (the agent said so) and orphaned claims
  qualify; reasons still come from
  `Casein.Attention.Delivery.session_classification/1` so this stays one ranker,
  not two (#787 / #788).

  Deliberately *not* attention:

    * `:ready_no_task` — a spawned worker with nothing to do is **capacity**.
      Filling it is the operator's call, not an interrupt.
    * `:stalled` / `:awaiting_input` — **derived**, never reported. They badge
      slate and sit in `:idle`, so an inference cannot manufacture a human lane.
    * quiet `:idle` / `:done` — quiet is quiet.

  This is one classifier for every fleet surface: the cockpit badge and drawer,
  `orchestration_status`, `orchestration_list_workers`, and `worker_status` all
  read it. It does **not** rewrite `Attention.Delivery` itself, which still
  drives the inbox / picker / notification path.

  ## Tickets

  A pane name is not work. `join_tickets/3` attaches a `Casein.Terminals.TicketFeed`
  ticket to each row by issue binding, by `#NNNN` in the label or window name,
  or by **PR head branch → worktree branch** — the common case on this fleet,
  where a worker has a PR and no issue at all. Rows sort as one continuous list
  by last ticket update; ticketless panes are leftover capacity and group below
  the live work rather than competing with it.
  """

  alias Casein.Attention.Delivery
  alias Casein.Attention.Salience
  alias Casein.Ops.GateQueue
  alias Casein.Terminals.FleetChrome
  alias Casein.Terminals.OrphanedClaims
  alias Casein.Terminals.TicketFeed

  @type bucket ::
          :needs_you | :working | :ready_no_task | :idle | :done | :unknown

  @type liveness_view :: %{
          optional(:state) => :active | :quiet | :unknown,
          optional(:reason) => atom() | String.t() | nil,
          optional(:quiet_for_seconds) => non_neg_integer() | nil,
          optional(:last_write_at) => String.t() | DateTime.t() | nil,
          optional(:commit_count) => non_neg_integer() | nil
        }

  @type blocked_on :: %{
          kind: :report | :derived | :unknown,
          reason: atom() | nil,
          detail: String.t() | nil
        }

  @type row :: %{
          window_id: String.t(),
          pane_id: String.t() | nil,
          name: String.t(),
          display_name: String.t(),
          agent_state: atom() | nil,
          agent_state_message: String.t() | nil,
          chip_text: String.t() | nil,
          chip_class: String.t() | nil,
          dot_class: String.t() | nil,
          label: String.t() | nil,
          issue: pos_integer() | nil,
          issue_title: String.t() | nil,
          task_summary: String.t() | nil,
          fleet_role: FleetChrome.fleet_role() | nil,
          fleet_readiness: FleetChrome.fleet_readiness() | nil,
          ready_no_task_for_seconds: non_neg_integer() | nil,
          quiet?: boolean(),
          unseen_quiet?: boolean(),
          needs_you?: boolean(),
          attention_reason: atom() | nil,
          bucket: bucket(),
          unknown_reason: atom() | String.t() | nil,
          active?: boolean(),
          liveness: liveness_view() | nil,
          blocked_on: blocked_on() | nil,
          worktree_path: String.t() | nil,
          ticket: TicketFeed.ticket() | nil,
          ticket_match: :issue_binding | :label | :branch | nil,
          capacity?: boolean(),
          parked?: boolean()
        }

  @type board :: %{
          rows: [row()],
          counts: %{optional(bucket()) => non_neg_integer()},
          attention_count: non_neg_integer(),
          total: non_neg_integer(),
          empty?: boolean(),
          orphaned_claims: OrphanedClaims.snapshot(),
          gate_queue: map()
        }

  @bucket_order [:needs_you, :working, :ready_no_task, :idle, :done, :unknown]

  @doc "Stable bucket order for chrome (needs-you first)."
  @spec bucket_order() :: [bucket()]
  def bucket_order, do: @bucket_order

  @doc """
  Build a fleet board from render-ready window tabs (`SessionBarVM.window_tab/4`).

  Options:

    * `:agent_only` — when true (default), drop windows with no agent role and
      no known agent state (pure shell windows stay off the fleet board)
    * `:orphaned_claims` — precomputed `OrphanedClaims` snapshot; when omitted
      the board derives bound issue numbers from tabs and leaves observation
      as unknown unless `:claimed` / `:list_claimed` is also supplied
    * `:claimed` / `:list_claimed` / `:tmux_session` — forwarded to
      `OrphanedClaims.observe/1` when `:orphaned_claims` is omitted
    * `:gate_queue` — precomputed `GateQueue.observe/1` result map; when omitted
      the board observes the host lock (cached). Pass `GateQueue.unknown()` to
      skip observation (tests / offline).
  """
  @spec from_window_tabs([map()], keyword()) :: board()
  def from_window_tabs(tabs, opts \\ []) when is_list(tabs) do
    agent_only? = Keyword.get(opts, :agent_only, true)
    feed = Keyword.get(opts, :ticket_feed) || TicketFeed.unknown()

    rows =
      tabs
      |> Enum.map(&row_from_window_tab/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn row -> not agent_only? or fleet_row?(row) end)
      |> join_tickets(feed)

    counts =
      Enum.reduce(rows, empty_counts(), fn row, acc ->
        Map.update!(acc, row.bucket, &(&1 + 1))
      end)

    orphaned = resolve_orphaned_claims(rows, opts)
    orphan_attention = orphan_attention_count(orphaned)
    attention_count = Enum.count(rows, & &1.needs_you?) + orphan_attention

    # Parked work: claimed on GitHub, no live pane. It shows as a ticket row
    # with no WHO rather than only as a banner count, so unassigned work is
    # visible in the same list as the work that has someone on it.
    pane_total = length(rows)
    rows = sort_rows(rows ++ parked_rows(orphaned, feed), opts)

    %{
      rows: rows,
      counts: counts,
      attention_count: attention_count,
      # Fleet size is agents. Parked tickets are work without an agent, so they
      # appear as rows but must not inflate "N fleet".
      total: pane_total,
      empty?: rows == [],
      orphaned_claims: orphaned,
      gate_queue: resolve_gate_queue(opts),
      ticket_feed_state: Map.get(feed, :observe_state, :unknown)
    }
  end

  @doc """
  Attach tickets to rows.

  Match order — first hit wins, most explicit first:

    1. `IssueBinding` number already on the row (the claim protocol's own join)
    2. `#NNNN` in the chrome label or window name
    3. **PR head branch == the pane worktree's branch** (`branch_by_worktree`
       on the feed). This is the case that carries this fleet: PR work has no
       issue binding and no number in the window name.

  A row that matches nothing keeps `ticket: nil` and becomes `capacity?` unless
  it needs a human. Unknown feed → every row stays unjoined; the drawer renders
  "tickets unknown", never "no work".
  """
  @spec join_tickets([row()], map()) :: [row()]
  def join_tickets(rows, feed) when is_list(rows) and is_map(feed) do
    Enum.map(rows, fn row ->
      {ticket, match} = match_ticket(row, feed)

      row
      |> Map.put(:ticket, ticket)
      |> Map.put(:ticket_match, match)
      |> Map.put(:capacity?, is_nil(ticket) and not row.needs_you?)
    end)
  end

  def join_tickets(rows, _feed) when is_list(rows), do: rows

  @doc "Empty board for mount / no-session sockets."
  @spec empty() :: board()
  def empty do
    %{
      rows: [],
      counts: empty_counts(),
      attention_count: 0,
      total: 0,
      empty?: true,
      orphaned_claims: OrphanedClaims.unknown(),
      gate_queue: GateQueue.unknown(),
      ticket_feed_state: :unknown
    }
  end

  @doc "True when the board has any needs-you row or orphaned claim."
  @spec needs_attention?(board()) :: boolean()
  def needs_attention?(%{attention_count: n}) when is_integer(n) and n > 0, do: true
  def needs_attention?(_), do: false

  @doc """
  The jump-target rows, in board order.

  Membership is `needs_you?` — the projection of
  `Casein.Attention.Delivery.session_classification/1` — and deliberately **not**
  `bucket == :needs_you`. The two are not the same set: `bucket_for/4` promotes a
  `stalled` / `blocked` / `errored` row into the `:needs_you` bucket when
  readiness was nil, so it is surfaced rather than shown as a bare unknown, even
  though `needs_you?` stayed false. Bucketing is how a row is *displayed*;
  `needs_you?` is whether it is genuinely asking for you.

  Using the bucket here would give the leader key a third definition of "needs
  you" and let it land on a wedged-but-not-asking pane. #910 is explicit that two
  totals must never disagree: `attention_count` counts `needs_you?`, the badge
  renders that count, so the cycle has to walk the same set or the key and the
  badge drift. A jump target that is merely stalled is the noise an operator
  learns to ignore.

  Workspace-scoped, like the badge: the board is built from this session's
  `tmux_window_tabs`, so the cycle never crosses into another workspace.
  """
  @spec needs_you_rows(board()) :: [row()]
  def needs_you_rows(%{rows: rows}) when is_list(rows), do: Enum.filter(rows, & &1.needs_you?)
  def needs_you_rows(_board), do: []

  @doc """
  The next needs-you row after `current_window_id`, wrapping; `nil` when none.

  From a window that is itself a jump target, this advances to the following one
  and wraps at the end, so repeated presses walk the whole set. From anywhere
  else — a quiet window, the shell, no active window — it lands on the first
  target, which is what makes the first press answer "who needs me?".
  """
  @spec next_needs_you(board(), String.t() | nil) :: row() | nil
  def next_needs_you(board, current_window_id \\ nil) do
    case needs_you_rows(board) do
      [] ->
        nil

      rows ->
        case Enum.find_index(rows, &(&1.window_id == current_window_id)) do
          nil -> List.first(rows)
          index -> Enum.at(rows, rem(index + 1, length(rows)))
        end
    end
  end

  ## Internals

  defp row_from_window_tab(tab) when is_map(tab) do
    window_id = Map.get(tab, :id) || Map.get(tab, "id")
    if not is_binary(window_id) or window_id == "", do: throw(:skip)

    agent_state = normalize_state(Map.get(tab, :agent_state) || Map.get(tab, "agent_state"))

    message =
      blank_to_nil(Map.get(tab, :agent_state_message) || Map.get(tab, "agent_state_message"))

    fleet_role = normalize_role(Map.get(tab, :fleet_role) || Map.get(tab, "fleet_role"))

    fleet_readiness =
      normalize_readiness(Map.get(tab, :fleet_readiness) || Map.get(tab, "fleet_readiness"))

    ready_for =
      case Map.get(tab, :ready_no_task_for_seconds) || Map.get(tab, "ready_no_task_for_seconds") do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end

    quiet? = Map.get(tab, :quiet?) == true or Map.get(tab, :quiet) == true
    unseen_quiet? = Map.get(tab, :unseen_quiet?) == true

    {needs_you?, attention_reason} =
      needs_you_projection(agent_state, quiet?, fleet_readiness)

    liveness = liveness_from_tab(tab)
    {bucket, unknown_reason} = bucket_for(needs_you?, agent_state, fleet_readiness, liveness)
    blocked_on = blocked_on_from(agent_state, message, attention_reason, liveness)

    %{
      window_id: window_id,
      pane_id: blank_to_nil(Map.get(tab, :agent_pane_id) || Map.get(tab, "agent_pane_id")),
      name: to_string(Map.get(tab, :name) || Map.get(tab, "name") || window_id),
      display_name:
        to_string(
          Map.get(tab, :display_name) || Map.get(tab, "display_name") ||
            Map.get(tab, :name) || window_id
        ),
      agent_state: agent_state,
      agent_state_message: message,
      chip_text:
        blank_to_nil(Map.get(tab, :agent_state_chip) || Map.get(tab, "agent_state_chip")),
      chip_class:
        blank_to_nil(
          Map.get(tab, :agent_state_chip_class) || Map.get(tab, "agent_state_chip_class")
        ),
      dot_class: blank_to_nil(Map.get(tab, :activity_class) || Map.get(tab, "activity_class")),
      label: blank_to_nil(Map.get(tab, :label) || Map.get(tab, "label")),
      issue: normalize_issue(Map.get(tab, :issue) || Map.get(tab, "issue")),
      issue_title: blank_to_nil(Map.get(tab, :issue_title) || Map.get(tab, "issue_title")),
      task_summary: blank_to_nil(Map.get(tab, :task_summary) || Map.get(tab, "task_summary")),
      fleet_role: fleet_role,
      fleet_readiness: fleet_readiness,
      ready_no_task_for_seconds: ready_for,
      quiet?: quiet?,
      unseen_quiet?: unseen_quiet?,
      needs_you?: needs_you?,
      attention_reason: attention_reason,
      bucket: bucket,
      unknown_reason: unknown_reason,
      active?: Map.get(tab, :active?) == true or Map.get(tab, :active) == true,
      liveness: liveness,
      blocked_on: blocked_on,
      worktree_path: blank_to_nil(Map.get(tab, :worktree_path) || Map.get(tab, "worktree_path")),
      ticket: nil,
      ticket_match: nil,
      capacity?: false,
      parked?: false
    }
  catch
    :skip -> nil
  end

  defp row_from_window_tab(_), do: nil

  # External observation only. Missing liveness is nil (not observed), never quiet.
  # `:unknown` keeps its reason so chrome cannot render "could not observe" as idle.
  defp liveness_from_tab(tab) when is_map(tab) do
    case Map.get(tab, :liveness) || Map.get(tab, "liveness") do
      nil ->
        nil

      %{state: state} = live ->
        normalize_liveness(state, live)

      %{"state" => state} = live ->
        normalize_liveness(state, live)

      state when state in [:active, :quiet, :unknown, "active", "quiet", "unknown"] ->
        normalize_liveness(state, %{})

      _ ->
        %{state: :unknown, reason: :malformed}
    end
  end

  defp normalize_liveness(state, live) do
    state = normalize_liveness_state(state)

    base = %{
      state: state,
      quiet_for_seconds: liveness_int(live, :quiet_for_seconds),
      last_write_at: liveness_time(live, :last_write_at),
      commit_count: liveness_int(live, :commit_count)
    }

    case state do
      :unknown ->
        Map.put(base, :reason, liveness_reason(live))

      _ ->
        base
    end
  end

  defp normalize_liveness_state(state) when state in [:active, :quiet, :unknown], do: state
  defp normalize_liveness_state("active"), do: :active
  defp normalize_liveness_state("quiet"), do: :quiet
  defp normalize_liveness_state("unknown"), do: :unknown
  defp normalize_liveness_state(_), do: :unknown

  defp liveness_int(live, key) when is_map(live) do
    case Map.get(live, key) || Map.get(live, Atom.to_string(key)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp liveness_time(live, key) when is_map(live) do
    case Map.get(live, key) || Map.get(live, Atom.to_string(key)) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp liveness_reason(live) when is_map(live) do
    case Map.get(live, :reason) || Map.get(live, "reason") do
      r when is_atom(r) -> r
      r when is_binary(r) and r != "" -> r
      _ -> :unscanned
    end
  end

  # Structured "blocked on what?" — report-only vs derived-only stay distinct.
  # Never invent a blocker for :working/:idle/:done without an attention reason.
  defp blocked_on_from(:blocked, message, _reason, _liveness) do
    %{kind: :report, reason: :blocked, detail: message}
  end

  defp blocked_on_from(:errored, message, _reason, _liveness) do
    %{kind: :report, reason: :errored, detail: message}
  end

  defp blocked_on_from(:stalled, message, _reason, liveness) do
    detail =
      message ||
        case liveness do
          %{quiet_for_seconds: s} when is_integer(s) and s > 0 ->
            "worktree quiet #{s}s while pane looks busy"

          _ ->
            "worktree quiet while pane looks busy"
        end

    %{kind: :derived, reason: :stalled, detail: detail}
  end

  defp blocked_on_from(:awaiting_input, message, _reason, _liveness) do
    %{
      kind: :derived,
      reason: :awaiting_input,
      detail: message || "agent stopped on its own turn and went quiet"
    }
  end

  defp blocked_on_from(_state, _message, :ready_no_task, _liveness) do
    %{kind: :derived, reason: :ready_no_task, detail: "idle capacity, no issue binding"}
  end

  defp blocked_on_from(_state, message, reason, _liveness)
       when reason in [:blocked, :errored, :stalled, :awaiting_input, :idle, :orphaned_claim] do
    kind = if reason in [:blocked, :errored], do: :report, else: :derived
    %{kind: kind, reason: reason, detail: message}
  end

  defp blocked_on_from(_state, _message, _reason, _liveness), do: nil

  defp fleet_row?(%{agent_state: state})
       when state in [:working, :blocked, :done, :idle, :errored, :stalled, :awaiting_input],
       do: true

  defp fleet_row?(%{fleet_role: role}) when role in [:manager, :worker], do: true
  defp fleet_row?(%{issue: n}) when is_integer(n), do: true
  defp fleet_row?(%{fleet_readiness: :ready_no_task}), do: true
  defp fleet_row?(%{quiet?: true}), do: true
  defp fleet_row?(_), do: false

  # Report-kind only. Ordered so a blocked worker that is also ready-no-task is
  # still attention — the human block is the stronger fact.
  defp needs_you_projection(agent_state, quiet?, fleet_readiness) do
    cond do
      agent_state in [:blocked, :errored] ->
        cls =
          %{windows: [%{agent_state: agent_state, quiet: false}]}
          |> Salience.facts_from_session()
          |> Salience.compute()
          |> Delivery.session_classification()

        {cls.section == :needs_you, cls.reason}

      fleet_readiness == :ready_no_task ->
        {false, :ready_no_task}

      # Derived, never reported: badge it, do not summon anyone.
      agent_state in [:stalled, :awaiting_input] ->
        {false, agent_state}

      quiet? and agent_state in [:done, :idle, nil] ->
        {false, :idle}

      true ->
        {false, nil}
    end
  end

  # Returns `{bucket, unknown_reason | nil}`. unknown_reason is set only when
  # bucket is :unknown — a bare unknown is the silent-failure class #916 fixes.
  defp bucket_for(true, _state, _readiness, _liveness), do: {:needs_you, nil}
  defp bucket_for(false, :working, _, _liveness), do: {:working, nil}
  defp bucket_for(false, _state, :ready_no_task, _liveness), do: {:ready_no_task, nil}
  defp bucket_for(false, :idle, _, _liveness), do: {:idle, nil}
  defp bucket_for(false, :done, _, _liveness), do: {:done, nil}

  # Cooperative agent_state absent (OpenCode / no hook report). Classify from
  # external liveness when observed — never invent idle from unscanned.
  defp bucket_for(false, nil, _readiness, %{state: :active}), do: {:working, nil}
  defp bucket_for(false, nil, _readiness, %{state: :quiet}), do: {:idle, nil}

  defp bucket_for(false, nil, _readiness, %{state: :unknown} = live) do
    {:unknown, liveness_unknown_reason(live)}
  end

  defp bucket_for(false, nil, _readiness, nil) do
    {:unknown, :agent_state_absent_liveness_not_observed}
  end

  # Report-kind: the agent said a human is needed. Already needs_you via
  # needs_you_projection; this clause keeps them off :unknown if they land here.
  defp bucket_for(false, state, _, _) when state in [:errored, :blocked],
    do: {:needs_you, nil}

  # Derived-kind. #917 bucketed these :needs_you to avoid a bare unknown; the
  # anti-bare-unknown property is what mattered, and :idle preserves it while
  # honouring the rule that an inference never summons a human. They still carry
  # `blocked_on` with kind: :derived, so the drawer can say *why* they are quiet.
  defp bucket_for(false, state, _, _) when state in [:stalled, :awaiting_input],
    do: {:idle, nil}

  defp bucket_for(false, state, _readiness, _liveness) do
    {:unknown, {:unmapped_agent_state, state}}
  end

  defp liveness_unknown_reason(%{reason: reason}) when is_atom(reason) and not is_nil(reason) do
    {:liveness_unknown, reason}
  end

  defp liveness_unknown_reason(%{reason: reason}) when is_binary(reason) and reason != "" do
    {:liveness_unknown, reason}
  end

  defp liveness_unknown_reason(_), do: :liveness_unknown

  # One continuous list of live work, newest ticket update first — not three
  # status columns. Triage survives via the needs-you badge on the row, and
  # ticketless capacity groups below rather than interleaving with #NNNN.
  defp sort_rows(rows, opts) do
    case Keyword.get(opts, :sort, :continuous) do
      :attention -> Enum.sort_by(rows, &attention_sort_key/1)
      _ -> Enum.sort_by(rows, &row_sort_key/1)
    end
  end

  defp row_sort_key(row) do
    {
      if(Map.get(row, :capacity?), do: 1, else: 0),
      -ticket_updated_unix(row),
      priority_rank(row),
      row.display_name
    }
  end

  defp attention_sort_key(row) do
    {
      bucket_rank(row.bucket),
      Delivery.session_reason_urgency(row.attention_reason || :recent),
      if(row.unseen_quiet?, do: 0, else: 1),
      -(row.ready_no_task_for_seconds || 0),
      row.display_name
    }
  end

  # No ticket, or a ticket with no timestamp, sinks within its group — a missing
  # `updatedAt` must not read as the freshest work.
  defp ticket_updated_unix(%{ticket: %{updated_at: %DateTime{} = dt}}), do: DateTime.to_unix(dt)
  defp ticket_updated_unix(_), do: 0

  defp priority_rank(%{ticket: %{priority: "p0"}}), do: 0
  defp priority_rank(%{ticket: %{priority: "p1"}}), do: 1
  defp priority_rank(%{ticket: %{priority: "p2"}}), do: 2
  defp priority_rank(_), do: 3

  ## Ticket join

  defp match_ticket(row, feed) do
    by_number = Map.get(feed, :by_number) || %{}

    with nil <- match_by_number(row.issue, by_number, :issue_binding),
         labelled = number_from_text(row.label) || number_from_text(row.name),
         nil <- match_by_number(labelled, by_number, :label),
         nil <- match_by_branch(row, feed) do
      {nil, nil}
    end
  end

  defp match_by_number(number, by_number, tag) when is_integer(number) do
    case Map.fetch(by_number, number) do
      {:ok, ticket} -> {ticket, tag}
      :error -> nil
    end
  end

  defp match_by_number(_number, _by_number, _tag), do: nil

  defp match_by_branch(%{worktree_path: path}, feed) when is_binary(path) do
    branches = Map.get(feed, :branch_by_worktree) || %{}
    by_head_ref = Map.get(feed, :by_head_ref) || %{}

    with branch when is_binary(branch) <- Map.get(branches, path),
         {:ok, ticket} <- Map.fetch(by_head_ref, branch) do
      {ticket, :branch}
    else
      _ -> nil
    end
  end

  defp match_by_branch(_row, _feed), do: nil

  # `#744` in "worker: #744 item 4" — a bare number is not a ticket reference,
  # so the `#` is required and a trailing word boundary keeps `#74` out of `#744`.
  defp number_from_text(text) when is_binary(text) do
    case Regex.run(~r/#(\d+)\b/, text) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  defp number_from_text(_), do: nil

  # Claimed on GitHub with no live pane. Rendered as a ticket row with no WHO.
  defp parked_rows(%{observe_state: :ok, orphans: orphans}, feed) when is_list(orphans) do
    by_number = Map.get(feed, :by_number) || %{}

    Enum.map(orphans, fn orphan ->
      ticket =
        Map.get(by_number, orphan.number) ||
          %{
            kind: :issue,
            number: orphan.number,
            title: orphan.title,
            url: orphan.url,
            updated_at: nil,
            head_ref: nil,
            draft?: false,
            labels: orphan.labels || [],
            priority: orphan.priority,
            repo: nil
          }

      %{
        window_id: "orphan-" <> Integer.to_string(orphan.number),
        pane_id: nil,
        name: "##{orphan.number}",
        display_name: ticket.title || "##{orphan.number}",
        agent_state: nil,
        agent_state_message: nil,
        chip_text: nil,
        chip_class: nil,
        dot_class: nil,
        label: nil,
        issue: orphan.number,
        issue_title: ticket.title,
        task_summary: nil,
        fleet_role: nil,
        fleet_readiness: nil,
        ready_no_task_for_seconds: nil,
        quiet?: false,
        unseen_quiet?: false,
        needs_you?: true,
        attention_reason: :orphaned_claim,
        bucket: :needs_you,
        unknown_reason: nil,
        active?: false,
        liveness: nil,
        blocked_on: nil,
        worktree_path: nil,
        ticket: ticket,
        ticket_match: nil,
        capacity?: false,
        parked?: true
      }
    end)
  end

  defp parked_rows(_orphaned, _feed), do: []

  defp bucket_rank(:needs_you), do: 0
  defp bucket_rank(:working), do: 1
  defp bucket_rank(:ready_no_task), do: 2
  defp bucket_rank(:idle), do: 3
  defp bucket_rank(:done), do: 4
  defp bucket_rank(:unknown), do: 5
  defp bucket_rank(_), do: 6

  defp empty_counts do
    Map.new(@bucket_order, &{&1, 0})
  end

  defp resolve_orphaned_claims(rows, opts) do
    case Keyword.fetch(opts, :orphaned_claims) do
      {:ok, %{} = snap} ->
        snap

      :error ->
        bound = Enum.flat_map(rows, fn row -> if row.issue, do: [row.issue], else: [] end)

        observe_opts =
          opts
          |> Keyword.take([:claimed, :list_claimed, :tmux_session, :repo, :workspace_label, :now])
          |> Keyword.put_new(:bound, bound)

        # Without a claimed source, stay unknown — never invent "no orphans".
        if Keyword.has_key?(observe_opts, :claimed) or
             Keyword.has_key?(observe_opts, :list_claimed) do
          OrphanedClaims.observe(observe_opts)
        else
          OrphanedClaims.unknown(reason: :no_claimed_source)
          |> Map.put(:bound_issues, Enum.uniq(bound) |> Enum.sort())
          |> Map.put(:bound_count, length(Enum.uniq(bound)))
        end
    end
  end

  defp resolve_gate_queue(opts) do
    snap =
      case Keyword.fetch(opts, :gate_queue) do
        {:ok, %{} = snap} ->
          snap

        :error ->
          case GateQueue.observe() do
            {:ok, snap} -> snap
            {:error, _} -> GateQueue.unknown()
          end
      end

    GateQueue.with_positions(snap)
  end

  defp orphan_attention_count(%{observe_state: :ok, orphan_count: n})
       when is_integer(n) and n > 0,
       do: n

  defp orphan_attention_count(_), do: 0

  defp normalize_state(state)
       when state in [:working, :blocked, :done, :idle, :errored, :stalled, :awaiting_input],
       do: state

  defp normalize_state("working"), do: :working
  defp normalize_state("blocked"), do: :blocked
  defp normalize_state("done"), do: :done
  defp normalize_state("idle"), do: :idle
  defp normalize_state("errored"), do: :errored
  defp normalize_state("stalled"), do: :stalled
  defp normalize_state("awaiting_input"), do: :awaiting_input
  defp normalize_state(_), do: nil

  defp normalize_role(role) when role in [:manager, :worker], do: role
  defp normalize_role("manager"), do: :manager
  defp normalize_role("worker"), do: :worker
  defp normalize_role(_), do: nil

  defp normalize_readiness(:ready_no_task), do: :ready_no_task
  defp normalize_readiness("ready_no_task"), do: :ready_no_task
  defp normalize_readiness(_), do: nil

  defp normalize_issue(n) when is_integer(n) and n > 0, do: n

  defp normalize_issue(n) when is_binary(n) do
    case Integer.parse(String.trim_leading(String.trim(n), "#")) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp normalize_issue(_), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
