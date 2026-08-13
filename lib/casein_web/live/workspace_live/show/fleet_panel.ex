defmodule CaseinWeb.WorkspaceLive.Show.FleetPanel do
  @moduledoc """
  Operator fleet board: aggregate "what are my workers doing?" chrome.

  Projection only — rows come from `Casein.Terminals.FleetBoard` over
  `tmux_window_tabs`. Clicking a row selects that tmux window
  (`tmux:select_window`). Always mounted so the badge can surface attention
  without a separate store.
  """

  use CaseinWeb, :html

  alias Casein.Ops.GateQueue
  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.OrphanedClaims

  attr :board, :map, required: true
  attr :open, :boolean, required: true

  def fleet_badge(assigns) do
    board = assigns.board || FleetBoard.empty()
    attention = Map.get(board, :attention_count, 0)
    total = Map.get(board, :total, 0)
    orphans = Map.get(board, :orphaned_claims) || OrphanedClaims.unknown()
    orphan_unknown? = OrphanedClaims.unknown?(orphans)
    gate = Map.get(board, :gate_queue) || GateQueue.unknown()
    gate_busy? = GateQueue.busy?(gate)

    assigns =
      assign(assigns,
        board: board,
        attention: attention,
        total: total,
        orphans: orphans,
        orphan_unknown?: orphan_unknown?,
        gate: gate,
        gate_busy?: gate_busy?
      )

    ~H"""
    <%!-- Two targets in one pill. The "N need you" half jumps straight to the
    next pane asking for you (same event as C-b a); the rest still opens the
    drawer, so nothing that was reachable by clicking became unreachable. With
    zero attention there is only the drawer button, exactly as before. --%>
    <div
      id="fleet-badge"
      class={[
        "fixed bottom-3 right-3 z-30 flex items-center gap-1.5 rounded-full border px-2.5 py-1 font-mono text-density-body shadow-sm",
        badge_class(@attention, @gate_busy?, @orphan_unknown?)
      ]}
      title={"Fleet board — " <> badge_title(@gate, @orphans)}
    >
      <span class={"inline-block h-1.5 w-1.5 rounded-full " <> attention_dot_class(@attention, @gate_busy?, @orphan_unknown?)}></span>
      <button
        :if={@attention > 0}
        id="fleet-badge-jump"
        type="button"
        phx-click="fleet:jump_needs_you"
        class="font-mono underline-offset-2 hover:underline"
        title="Jump to the next pane that needs you (C-b a)"
      >
        {@attention} need you
      </button>
      <button
        id="fleet-badge-drawer"
        type="button"
        phx-click="fleet_drawer:toggle"
        class="font-mono"
        title="Open the fleet board"
      >
        <%= cond do %>
          <% @attention > 0 -> %>
            · {@total} fleet
          <% @gate_busy? -> %>
            fleet · {@total} · gate busy
          <% @orphan_unknown? -> %>
            fleet · {@total} · claims ?
          <% true -> %>
            fleet · {@total}
        <% end %>
      </button>
    </div>
    """
  end

  attr :board, :map, required: true
  attr :open, :boolean, required: true
  attr :workspace, :map, required: true
  attr :active_window_id, :any, default: nil

  def fleet_drawer(assigns) do
    board = assigns.board || FleetBoard.empty()
    rows = Map.get(board, :rows, [])
    counts = Map.get(board, :counts, %{})
    orphans = Map.get(board, :orphaned_claims) || OrphanedClaims.unknown()
    gate = Map.get(board, :gate_queue) || GateQueue.unknown()

    assigns =
      assign(assigns, board: board, rows: rows, counts: counts, orphans: orphans, gate: gate)

    ~H"""
    <div :if={@open} class="fixed inset-0 z-40 pointer-events-none" aria-hidden="false">
      <div class="absolute inset-0 bg-black/20 pointer-events-auto" phx-click="fleet_drawer:close">
      </div>
      <aside
        id="fleet-drawer"
        class="absolute right-0 top-0 bottom-0 flex w-[min(420px,100vw)] flex-col border-l bg-base-100 shadow-xl pointer-events-auto"
        role="complementary"
        aria-label="Fleet board"
      >
        <header class="flex items-center justify-between gap-2 border-b px-4 py-3">
          <div class="min-w-0">
            <h2 class="text-sm font-semibold tracking-tight">Fleet</h2>
            <p
              class="font-mono text-density-body text-base-content/60"
              title={count_population_title()}
            >
              {Map.get(@board, :total, 0)} agent windows · {Map.get(@board, :attention_count, 0)} need you · {@workspace.name}
            </p>
          </div>
          <button
            type="button"
            phx-click="fleet_drawer:close"
            class="rounded border px-2 py-density-body text-density-body hover:bg-base-200"
            title="close"
          >
            ×
          </button>
        </header>

        <div
          id="fleet-gate-queue"
          class={"border-b px-3 py-2 font-mono text-density-label " <> gate_banner_class(@gate)}
        >
          <div class="flex items-center gap-2">
            <span class={"inline-block h-1.5 w-1.5 shrink-0 rounded-full " <> gate_dot_class(@gate)}></span>
            <span class="min-w-0 flex-1 truncate font-medium">{GateQueue.summary(@gate)}</span>
            <span
              :if={gate_depth(@gate)}
              class="shrink-0 rounded border border-current/20 px-1.5 py-0.5"
            >
              depth {gate_depth(@gate)}
            </span>
          </div>
          <div
            :if={gate_holder_detail(@gate)}
            class="mt-1 pl-3.5 text-base-content/60 truncate"
          >
            {gate_holder_detail(@gate)}
          </div>
          <ol
            :if={gate_queue_entries(@gate) != []}
            id="fleet-gate-queue-positions"
            class="mt-1.5 space-y-0.5 pl-3.5 text-base-content/70"
          >
            <li
              :for={entry <- gate_queue_entries(@gate)}
              id={"fleet-gate-pos-" <> Integer.to_string(entry.position)}
              class="flex min-w-0 items-center gap-2"
            >
              <span class="shrink-0 font-medium">#{entry.position}</span>
              <span class="min-w-0 flex-1 truncate">{entry.label}</span>
              <span class="shrink-0 text-base-content/50">{entry.role}</span>
            </li>
          </ol>
        </div>

        <div
          id="fleet-orphaned-claims"
          class={"border-b px-3 py-2 font-mono text-density-label " <> orphan_banner_class(@orphans)}
        >
          <div class="flex items-center gap-2">
            <span class={"inline-block h-1.5 w-1.5 shrink-0 rounded-full " <> orphan_dot_class(@orphans)}></span>
            <span class="min-w-0 flex-1 truncate font-medium">{OrphanedClaims.summary(@orphans)}</span>
            <span
              :if={orphan_count_chip(@orphans)}
              class="shrink-0 rounded border border-current/20 px-1.5 py-0.5"
            >
              {orphan_count_chip(@orphans)}
            </span>
          </div>
          <p
            :if={OrphanedClaims.any?(@orphans)}
            id="fleet-orphaned-claim-list"
            class="mt-1 pl-3.5 text-base-content/60"
          >
            listed below as parked ticket rows
          </p>
          <p
            :if={OrphanedClaims.unknown?(@orphans)}
            class="mt-1 pl-3.5 text-base-content/50"
          >
            claimed set not observed — not the same as zero orphans
          </p>
        </div>

        <div class="flex flex-wrap gap-1.5 border-b px-3 py-2 font-mono text-density-label">
          <span
            :for={bucket <- FleetBoard.bucket_order()}
            :if={Map.get(@counts, bucket, 0) > 0}
            class={"rounded-full border px-2 py-0.5 " <> count_chip_class(bucket)}
          >
            {bucket_label(bucket)} {Map.get(@counts, bucket, 0)}
          </span>
          <span :if={@rows == []} class="text-base-content/40">no agent windows in this session</span>
        </div>

        <div class="flex-1 overflow-auto px-2 py-2 text-density-body leading-relaxed">
          <ol id="fleet-board-rows" class="space-y-1">
            <li :for={row <- live_rows(@rows)}>
              <button
                type="button"
                id={"fleet-row-" <> row.window_id}
                phx-click={not row.parked? && "tmux:select_window"}
                phx-value-window-id={row.window_id}
                class={[
                  "flex w-full flex-col gap-0.5 rounded border px-2.5 py-1.5 text-left transition-colors",
                  row_class(row, @active_window_id)
                ]}
                title={row_title(row)}
              >
                <div class="flex min-w-0 items-center gap-2">
                  <span
                    :if={row.ticket}
                    class={"shrink-0 rounded border px-1 py-0.5 font-mono text-density-label " <> ticket_chip_class(row.ticket)}
                  >
                    {ticket_kind_label(row.ticket)} {row.ticket.number}
                  </span>
                  <span
                    :if={is_nil(row.ticket)}
                    class={"inline-block h-2 w-2 shrink-0 rounded-full " <> (row.dot_class || "bg-base-content/20")}
                  ></span>
                  <span class="min-w-0 flex-1 truncate font-medium">{row_title_text(row)}</span>
                  <span
                    :if={row.fleet_role}
                    class="shrink-0 rounded bg-base-200 px-1.5 py-0.5 font-mono text-density-label text-base-content/70"
                  >
                    {row.fleet_role}
                  </span>
                  <span class={"shrink-0 rounded px-1.5 py-0.5 font-mono text-density-label " <> who_chip_class(row)}>
                    {who_chip_label(row)}
                  </span>
                </div>
                <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 pl-4 font-mono text-density-label text-base-content/60">
                  <span :if={row.parked?} class="text-base-content/50">no pane</span>
                  <span :if={not row.parked?} class="shrink-0 text-base-content/80">
                    {row.name}
                  </span>
                  <span :if={row.ticket && row.task_summary} class="truncate">
                    {row.task_summary}
                  </span>
                  <span :if={row.fleet_readiness == :ready_no_task} class="text-base-content/50">
                    ready, no task{ready_for_suffix(row.ready_no_task_for_seconds)}
                  </span>
                  <span
                    :if={blocked_on_label(row)}
                    class={"truncate " <> blocked_on_class(row)}
                  >
                    blocked on: {blocked_on_label(row)}
                  </span>
                  <span
                    :if={is_nil(blocked_on_label(row)) and row.agent_state_message}
                    class="truncate text-base-content/50"
                  >
                    {row.agent_state_message}
                  </span>
                  <span
                    :if={unknown_reason_label(row)}
                    class="truncate text-base-content/50"
                    title="Casein could not classify this pane — this is why, not a claim that it is quiet"
                  >
                    can't classify: {unknown_reason_label(row)}
                  </span>
                  <span
                    :if={liveness_label(row)}
                    class={"shrink-0 " <> liveness_class(row)}
                  >
                    {liveness_label(row)}
                  </span>
                </div>
              </button>
            </li>
          </ol>

          <div
            :if={capacity_rows(@rows) != []}
            id="fleet-capacity"
            class="mt-3 border-t pt-2"
          >
            <p class="px-1 pb-1 font-mono text-density-label text-base-content/40">
              capacity · {length(capacity_rows(@rows))} pane(s), no ticket
            </p>
            <ol id="fleet-capacity-rows" class="space-y-1">
              <li :for={row <- capacity_rows(@rows)}>
                <button
                  type="button"
                  id={"fleet-row-" <> row.window_id}
                  phx-click="tmux:select_window"
                  phx-value-window-id={row.window_id}
                  class={[
                    "flex w-full items-center gap-2 rounded border border-transparent px-2.5 py-1",
                    "text-left text-base-content/60 transition-colors hover:bg-base-200/80"
                  ]}
                  title={"Focus window " <> row.name}
                >
                  <span class={"inline-block h-1.5 w-1.5 shrink-0 rounded-full " <> (row.dot_class || "bg-base-content/20")}></span>
                  <span class="min-w-0 flex-1 truncate">{row.display_name}</span>
                  <span
                    :if={row.fleet_readiness == :ready_no_task}
                    class="shrink-0 font-mono text-density-label text-base-content/40"
                  >
                    ready, no task{ready_for_suffix(row.ready_no_task_for_seconds)}
                  </span>
                  <span
                    :if={row.fleet_role}
                    class="shrink-0 font-mono text-density-label text-base-content/40"
                  >
                    {row.fleet_role}
                  </span>
                  <span class={"shrink-0 rounded px-1.5 py-0.5 font-mono text-density-label " <> who_chip_class(row)}>
                    {who_chip_label(row)}
                  </span>
                </button>
              </li>
            </ol>
          </div>
        </div>

        <footer class="border-t px-3 py-2 font-mono text-density-label text-base-content/50">
          projection · tickets {ticket_feed_label(@board)} · AgentState + IssueBinding + TicketFeed + GateQueue
        </footer>
      </aside>
    </div>
    """
  end

  defp badge_title(gate, orphans) do
    GateQueue.summary(gate) <> " · " <> OrphanedClaims.summary(orphans)
  end

  ## Ticket rows

  # Live work: anything with a ticket, plus anything that needs a human. A
  # ticketless quiet pane is capacity and belongs below the divider.
  defp live_rows(rows) when is_list(rows), do: Enum.reject(rows, & &1.capacity?)
  defp live_rows(_), do: []

  defp capacity_rows(rows) when is_list(rows), do: Enum.filter(rows, & &1.capacity?)
  defp capacity_rows(_), do: []

  defp ticket_kind_label(%{kind: :pr}), do: "PR"
  defp ticket_kind_label(_), do: "ISS"

  defp ticket_chip_class(%{kind: :pr}),
    do: "border-ticket-pr-border bg-ticket-pr-soft text-ticket-pr-fg"

  defp ticket_chip_class(_),
    do: "border-ticket-iss-border bg-ticket-iss-soft text-ticket-iss-fg"

  # The ticket title is the work; the pane name is only where it is being done.
  defp row_title_text(%{ticket: %{title: title}}) when is_binary(title) and title != "",
    do: title

  defp row_title_text(row), do: row.display_name

  defp row_title(%{parked?: true} = row), do: "Claimed, no live pane — #{row.name}"
  defp row_title(row), do: "Focus window " <> row.name

  ## WHO chip — five states, one colour rule: only a reported human block is warm.

  # Bucket-driven, not agent_state-driven. A hook-less OpenCode pane reports no
  # agent_state at all; #917 classifies it from liveness, and keying this chip
  # off agent_state would print "unknown" over a worker the board already knows
  # is working — the #916 bug wearing a different hat.
  #
  # agent_state only refines *within* a bucket, and it keeps the states the
  # taxonomy says are distinct distinct: wedged (stalled) is not idle, idle is
  # not quiet-with-no-task (ready), and neither is unknown.
  defp who_chip_label(%{parked?: true}), do: "parked"
  defp who_chip_label(%{agent_state: :blocked}), do: "blocked"
  defp who_chip_label(%{agent_state: :errored}), do: "error"
  defp who_chip_label(%{agent_state: :stalled}), do: "stalled"
  defp who_chip_label(%{agent_state: :awaiting_input}), do: "awaiting"
  defp who_chip_label(%{bucket: :needs_you}), do: "needs you"
  defp who_chip_label(%{bucket: :working}), do: "working"
  defp who_chip_label(%{bucket: :ready_no_task}), do: "ready"
  defp who_chip_label(%{bucket: :idle}), do: "idle"
  defp who_chip_label(%{bucket: :done}), do: "done"
  defp who_chip_label(_), do: "unknown"

  # Slate for everything quiet — ready / stalled / awaiting_input / idle / done.
  # Blue-busy is reserved for an agent that is actually working, amber for a
  # reported block. An inference never gets a warm colour.
  defp who_chip_class(%{agent_state: state}) when state in [:blocked, :errored],
    do: "bg-status-warning-soft text-status-warning-fg"

  defp who_chip_class(%{parked?: true}),
    do: "bg-status-warning-soft/60 text-status-warning-fg"

  defp who_chip_class(%{bucket: :needs_you}),
    do: "bg-status-warning-soft text-status-warning-fg"

  defp who_chip_class(%{bucket: :working}),
    do: "bg-status-ok/15 text-status-ok"

  # Could-not-classify gets its own dimmer treatment plus a printed reason, so it
  # reads as "no signal", never as an observed quiet.
  defp who_chip_class(%{bucket: :unknown}),
    do: "bg-base-200 text-base-content/40 italic"

  defp who_chip_class(_), do: "bg-base-200 text-base-content/50"

  # Derived blockers stay slate; only a reported one is amber.
  defp blocked_on_class(%{blocked_on: %{kind: :report}}), do: "text-status-warning-fg"
  defp blocked_on_class(_), do: "text-base-content/50"

  # Counts on fleet surfaces measure different populations on purpose and are
  # NOT reconciled into one number: a session's raw pane count includes shells
  # and preview panes; "agent windows" is what this board rows; `fleet_role=worker`
  # is a subset that legitimately excludes SUP/MGR panes. Same wording as the
  # `orchestration_status` note so the two surfaces explain themselves alike.
  defp count_population_title do
    "agent windows on this session (board rows). Not the session's raw pane count " <>
      "(shells and preview panes are excluded) and not the worker count " <>
      "(fleet_role=worker excludes SUP/MGR panes)."
  end

  # #916/#917: an unknown row must say why. Shared vocabulary with the wire.
  defp unknown_reason_label(%{bucket: :unknown} = row) do
    FleetBoard.unknown_reason_string(Map.get(row, :unknown_reason)) || "reason not recorded"
  end

  defp unknown_reason_label(_row), do: nil

  defp ticket_feed_label(board) do
    case Map.get(board, :ticket_feed_state) do
      :ok -> "live"
      _ -> "unknown"
    end
  end

  # attention > gate busy > claims unknown > default
  defp badge_class(n, _gate_busy?, _orphan_unknown?) when is_integer(n) and n > 0,
    do: "border-status-warning-border bg-status-warning-soft text-status-warning-fg"

  defp badge_class(_, true, _),
    do: "border-status-live-border bg-status-live-soft text-status-live-fg"

  defp badge_class(_, _, true),
    do: "border-base-300 bg-base-200 text-base-content/60"

  defp badge_class(_, _, _), do: "border-base-300 bg-base-100 text-base-content/70"

  defp attention_dot_class(n, _, _) when is_integer(n) and n > 0, do: "bg-status-warning"
  defp attention_dot_class(_, true, _), do: "bg-status-live"
  defp attention_dot_class(_, _, true), do: "bg-base-content/40"
  defp attention_dot_class(_, _, _), do: "bg-base-content/30"

  defp orphan_banner_class(%{observe_state: :ok, orphan_count: n})
       when is_integer(n) and n > 0,
       do: "bg-status-warning-soft/40 text-status-warning-fg"

  defp orphan_banner_class(%{observe_state: :unknown}),
    do: "bg-base-200/60 text-base-content/50"

  defp orphan_banner_class(_), do: "bg-base-200/40 text-base-content/60"

  defp orphan_dot_class(%{observe_state: :ok, orphan_count: n})
       when is_integer(n) and n > 0,
       do: "bg-status-warning"

  defp orphan_dot_class(%{observe_state: :ok}), do: "bg-status-ok"
  defp orphan_dot_class(_), do: "bg-base-content/30"

  defp orphan_count_chip(%{observe_state: :ok, orphan_count: n}) when is_integer(n), do: n
  defp orphan_count_chip(%{observe_state: :unknown}), do: "?"
  defp orphan_count_chip(_), do: nil

  defp gate_banner_class(%{lock_state: :held}),
    do: "bg-status-live-soft/40 text-status-live-fg"

  defp gate_banner_class(%{lock_state: :unknown}),
    do: "bg-base-200/60 text-base-content/50"

  defp gate_banner_class(_), do: "bg-base-200/40 text-base-content/60"

  defp gate_dot_class(%{lock_state: :held}), do: "bg-status-live"
  defp gate_dot_class(%{lock_state: :free}), do: "bg-status-ok"
  defp gate_dot_class(_), do: "bg-base-content/30"

  defp gate_depth(%{lock_state: state, depth: d})
       when state in [:held, :free] and is_integer(d),
       do: d

  defp gate_depth(_), do: nil

  defp gate_holder_detail(%{lock_state: :held, holder: h}) when is_map(h) do
    parts =
      [
        h[:branch],
        h[:sha] && String.slice(to_string(h[:sha]), 0, 7),
        h[:run_id] && "run #{h[:run_id]}",
        h[:pid] && "pid #{h[:pid]}"
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, " · ")
  end

  defp gate_holder_detail(_), do: nil

  # Ordered queue: holder position 1, waiters 2..n. Unknown/free → no list
  # (never invent a calm empty queue when observation failed).
  defp gate_queue_entries(%{lock_state: :held} = gate) do
    holder = Map.get(gate, :holder)
    waiters = Map.get(gate, :waiters) || []

    holder_entry =
      if is_map(holder) do
        [
          %{
            position: Map.get(holder, :position) || 1,
            label: gate_entry_label(holder),
            role: "holding"
          }
        ]
      else
        []
      end

    waiter_entries =
      waiters
      |> Enum.with_index(2)
      |> Enum.map(fn {w, idx} ->
        %{
          position: (is_map(w) && Map.get(w, :position)) || idx,
          label: gate_entry_label(w),
          role: "waiting"
        }
      end)

    holder_entry ++ waiter_entries
  end

  defp gate_queue_entries(_), do: []

  defp gate_entry_label(%{pr: pr}) when is_integer(pr), do: "PR ##{pr}"
  defp gate_entry_label(%{branch: b}) when is_binary(b) and b != "", do: b
  defp gate_entry_label(%{run_id: id}) when is_binary(id) and id != "", do: "run #{id}"
  defp gate_entry_label(%{pid: pid}) when is_integer(pid), do: "pid #{pid}"
  defp gate_entry_label(_), do: "unknown"

  defp count_chip_class(:needs_you),
    do: "border-status-danger-border bg-status-danger-soft text-status-danger-fg"

  defp count_chip_class(:working),
    do: "border-status-ok/40 bg-status-ok/10 text-status-ok"

  # Capacity is slate like every other quiet bucket. Only needs_you is warm —
  # an amber "ready 4" chip was the badge lying about idle workers in miniature.
  defp count_chip_class(_), do: "border-base-300 bg-base-200 text-base-content/70"

  defp bucket_label(:needs_you), do: "need you"
  defp bucket_label(:working), do: "working"
  defp bucket_label(:ready_no_task), do: "ready"
  defp bucket_label(:idle), do: "idle"
  defp bucket_label(:done), do: "done"
  defp bucket_label(:unknown), do: "unknown"
  defp bucket_label(other), do: to_string(other)

  defp row_class(row, active_window_id) do
    cond do
      row.window_id == active_window_id ->
        "border-primary/50 bg-primary/5"

      row.needs_you? ->
        "border-status-warning-border/60 bg-status-warning-soft/40 hover:bg-status-warning-soft"

      true ->
        "border-base-300 hover:bg-base-200/80"
    end
  end

  defp ready_for_suffix(n) when is_integer(n) and n >= 60, do: " · #{div(n, 60)}m"
  defp ready_for_suffix(n) when is_integer(n) and n > 0, do: " · #{n}s"
  defp ready_for_suffix(_), do: ""

  defp blocked_on_label(%{blocked_on: %{detail: d}}) when is_binary(d) and d != "", do: d

  defp blocked_on_label(%{blocked_on: %{reason: r}}) when not is_nil(r),
    do: to_string(r)

  defp blocked_on_label(%{agent_state: state, agent_state_message: msg})
       when state in [:blocked, :errored, :stalled] and is_binary(msg) and msg != "",
       do: msg

  defp blocked_on_label(%{agent_state: state}) when state in [:blocked, :errored, :stalled],
    do: to_string(state)

  defp blocked_on_label(_), do: nil

  # unknown ≠ quiet: missing observation is omitted; :unknown is labelled as such.
  defp liveness_label(%{liveness: %{state: :active} = live}) do
    case Map.get(live, :quiet_for_seconds) do
      n when is_integer(n) and n > 0 -> "live · wrote #{ago_suffix(n)}"
      _ -> "live"
    end
  end

  defp liveness_label(%{liveness: %{state: :quiet} = live}) do
    case Map.get(live, :quiet_for_seconds) do
      n when is_integer(n) and n > 0 -> "quiet #{ago_suffix(n)}"
      _ -> "quiet"
    end
  end

  defp liveness_label(%{liveness: %{state: :unknown} = live}) do
    case Map.get(live, :reason) do
      r when is_atom(r) and r != nil -> "liveness ? (#{r})"
      r when is_binary(r) and r != "" -> "liveness ? (#{r})"
      _ -> "liveness ?"
    end
  end

  defp liveness_label(_), do: nil

  defp liveness_class(%{liveness: %{state: :active}}), do: "text-status-ok"
  defp liveness_class(%{liveness: %{state: :quiet}}), do: "text-base-content/50"
  defp liveness_class(%{liveness: %{state: :unknown}}), do: "text-base-content/40"

  defp ago_suffix(n) when is_integer(n) and n >= 60, do: "#{div(n, 60)}m ago"
  defp ago_suffix(n) when is_integer(n) and n > 0, do: "#{n}s ago"
  defp ago_suffix(_), do: ""
end
