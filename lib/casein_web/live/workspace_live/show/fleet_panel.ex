defmodule CaseinWeb.WorkspaceLive.Show.FleetPanel do
  @moduledoc """
  Operator fleet board: aggregate "what are my workers doing?" chrome.

  Projection only — rows come from `Casein.Terminals.FleetBoard` over
  `tmux_window_tabs`. Clicking a row selects that tmux window
  (`tmux:select_window`). Always mounted so the badge can surface attention
  without a separate store.
  """

  use CaseinWeb, :html

  alias Casein.Terminals.FleetBoard

  attr :board, :map, required: true
  attr :open, :boolean, required: true

  def fleet_badge(assigns) do
    board = assigns.board || FleetBoard.empty()
    attention = Map.get(board, :attention_count, 0)
    total = Map.get(board, :total, 0)
    assigns = assign(assigns, board: board, attention: attention, total: total)

    ~H"""
    <button
      id="fleet-badge"
      phx-click="fleet_drawer:toggle"
      class={[
        "fixed bottom-3 right-3 z-30 flex items-center gap-1.5 rounded-full border px-2.5 py-1 font-mono text-density-body shadow-sm",
        badge_class(@attention)
      ]}
      title="Fleet board — worker states across this session"
    >
      <span class={"inline-block h-1.5 w-1.5 rounded-full " <> attention_dot_class(@attention)}></span>
      <%= if @attention > 0 do %>
        {@attention} need you · {@total} fleet
      <% else %>
        fleet · {@total}
      <% end %>
    </button>
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
    assigns = assign(assigns, board: board, rows: rows, counts: counts)

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
            <p class="font-mono text-density-body text-base-content/60">
              {Map.get(@board, :total, 0)} agents · {Map.get(@board, :attention_count, 0)} need you · {@workspace.name}
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
            <li :for={row <- @rows}>
              <button
                type="button"
                id={"fleet-row-" <> row.window_id}
                phx-click="tmux:select_window"
                phx-value-window-id={row.window_id}
                class={[
                  "flex w-full flex-col gap-0.5 rounded border px-2.5 py-1.5 text-left transition-colors",
                  row_class(row, @active_window_id)
                ]}
                title={"Focus window " <> row.name}
              >
                <div class="flex min-w-0 items-center gap-2">
                  <span class={"inline-block h-2 w-2 shrink-0 rounded-full " <> (row.dot_class || "bg-base-content/20")}></span>
                  <span class="min-w-0 flex-1 truncate font-medium">{row.display_name}</span>
                  <span
                    :if={row.fleet_role}
                    class="shrink-0 rounded bg-base-200 px-1.5 py-0.5 font-mono text-density-label text-base-content/70"
                  >
                    {row.fleet_role}
                  </span>
                  <span
                    :if={row.chip_text}
                    class={"shrink-0 rounded px-1.5 py-0.5 font-mono text-density-label " <> (row.chip_class || "")}
                  >
                    {row.chip_text}
                  </span>
                  <span
                    :if={row.needs_you? and is_nil(row.chip_text)}
                    class="shrink-0 rounded bg-status-warning/15 px-1.5 py-0.5 font-mono text-density-label text-status-warning-fg"
                  >
                    {attention_chip(row)}
                  </span>
                </div>
                <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 pl-4 font-mono text-density-label text-base-content/60">
                  <span :if={row.issue} class="text-base-content/80">#{row.issue}</span>
                  <span :if={row.issue_title} class="truncate">{row.issue_title}</span>
                  <span :if={row.task_summary && is_nil(row.issue_title)} class="truncate">
                    {row.task_summary}
                  </span>
                  <span :if={row.label && is_nil(row.task_summary)} class="truncate">{row.label}</span>
                  <span :if={row.fleet_readiness == :ready_no_task} class="text-status-warning-fg">
                    ready, no task{ready_for_suffix(row.ready_no_task_for_seconds)}
                  </span>
                  <span :if={row.agent_state_message} class="truncate text-base-content/50">
                    {row.agent_state_message}
                  </span>
                </div>
              </button>
            </li>
          </ol>
        </div>

        <footer class="border-t px-3 py-2 font-mono text-density-label text-base-content/50">
          projection · AgentState + IssueBinding + FleetChrome · click focuses window
        </footer>
      </aside>
    </div>
    """
  end

  defp badge_class(n) when is_integer(n) and n > 0,
    do: "border-status-warning-border bg-status-warning-soft text-status-warning-fg"

  defp badge_class(_), do: "border-base-300 bg-base-100 text-base-content/70"

  defp attention_dot_class(n) when is_integer(n) and n > 0, do: "bg-status-warning"
  defp attention_dot_class(_), do: "bg-base-content/30"

  defp count_chip_class(:needs_you),
    do: "border-status-danger-border bg-status-danger-soft text-status-danger-fg"

  defp count_chip_class(:working),
    do: "border-status-ok/40 bg-status-ok/10 text-status-ok"

  defp count_chip_class(:ready_no_task),
    do: "border-status-warning-border bg-status-warning-soft text-status-warning-fg"

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

  defp attention_chip(%{attention_reason: :ready_no_task}), do: "ready"
  defp attention_chip(%{attention_reason: :idle}), do: "quiet"
  defp attention_chip(%{attention_reason: :blocked}), do: "needs input"
  defp attention_chip(%{attention_reason: :errored}), do: "error"
  defp attention_chip(%{attention_reason: :stalled}), do: "stalled"
  defp attention_chip(%{attention_reason: reason}) when is_atom(reason), do: to_string(reason)
  defp attention_chip(_), do: "needs you"

  defp ready_for_suffix(n) when is_integer(n) and n >= 60, do: " · #{div(n, 60)}m"
  defp ready_for_suffix(n) when is_integer(n) and n > 0, do: " · #{n}s"
  defp ready_for_suffix(_), do: ""
end
