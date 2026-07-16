defmodule DevIdeWeb.WorkspaceLive.Show.AgentOperationsPanel do
  @moduledoc false

  use DevIdeWeb, :html

  attr :workspace, :map, required: true
  attr :loaded?, :boolean, required: true
  attr :threads, :list, required: true
  attr :approvals, :list, required: true
  attr :selected_thread_id, :string, default: nil
  attr :timeline, :list, required: true
  attr :live_delta, :string, default: ""
  attr :exec_form, :map, required: true
  attr :exec_run, :map, default: nil
  attr :error, :string, default: nil

  def agent_operations_panel(assigns) do
    assigns =
      assigns
      |> assign(:pending_approvals, Enum.filter(assigns.approvals, &(&1.status == "pending")))
      |> assign(:thread_tree, thread_tree(assigns.threads))
      |> assign(:selected_thread, selected_thread(assigns.threads, assigns.selected_thread_id))
      |> assign(:usage_totals, usage_totals(assigns.threads))

    ~H"""
    <section
      id="agent-operations-panel"
      class="flex h-full min-h-0 flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-sm"
    >
      <header class="flex shrink-0 flex-wrap items-center gap-3 border-b border-base-300 bg-base-200/45 px-4 py-3">
        <div class="flex min-w-0 flex-1 items-center gap-3">
          <span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary ring-1 ring-primary/20">
            <.icon name="hero-cpu-chip" class="size-5" />
          </span>
          <div class="min-w-0">
            <h2 class="truncate text-sm font-semibold text-base-content">Agent Operations</h2>
            <p class="truncate text-[11px] text-base-content/55">
              Protocol-native Codex threads, approvals, and usage
            </p>
          </div>
        </div>

        <div class="flex items-center gap-1.5 text-[11px]">
          <.metric_chip label="Threads" value={length(@threads)} />
          <.metric_chip
            label="Pending"
            value={length(@pending_approvals)}
            attention?={@pending_approvals != []}
          />
          <.metric_chip label="Tokens" value={compact_number(@usage_totals.total_tokens)} />
          <button
            type="button"
            phx-click="codex:refresh"
            class="ml-1 inline-flex size-8 items-center justify-center rounded-lg border border-base-300 bg-base-100 text-base-content/65 transition hover:-translate-y-px hover:border-primary/35 hover:text-primary"
            title="Refresh Codex operations"
            aria-label="Refresh Codex operations"
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
        </div>
      </header>

      <div :if={@error} class="border-b border-error/25 bg-error/10 px-4 py-2 text-xs text-error">
        {@error}
      </div>

      <div
        :if={!@loaded?}
        class="flex flex-1 items-center justify-center text-sm text-base-content/50"
      >
        Loading Codex operations…
      </div>

      <div :if={@loaded?} class="flex min-h-0 flex-1 flex-col">
        <section
          :if={@pending_approvals != []}
          id="codex-pending-approvals"
          class="shrink-0 border-b border-amber-400/25 bg-amber-400/[0.06] px-4 py-3"
          aria-label="Pending Codex approvals"
        >
          <div class="mb-2 flex items-center gap-2 text-xs font-semibold text-amber-700 dark:text-amber-300">
            <span class="relative flex size-2">
              <span class="absolute inline-flex size-full animate-ping rounded-full bg-amber-400 opacity-50"></span>
              <span class="relative inline-flex size-2 rounded-full bg-amber-500"></span>
            </span>
            Pending approvals stay visible across every thread
          </div>
          <div class="grid gap-2 lg:grid-cols-2 2xl:grid-cols-3">
            <.approval_card :for={approval <- @pending_approvals} approval={approval} />
          </div>
        </section>

        <div class="grid min-h-0 flex-1 lg:grid-cols-[19rem_minmax(0,1fr)]">
          <aside class="flex min-h-0 flex-col border-b border-base-300 bg-base-200/25 lg:border-r lg:border-b-0">
            <div class="shrink-0 border-b border-base-300 px-3 py-2.5">
              <p class="text-[10px] font-semibold uppercase tracking-[0.16em] text-base-content/45">
                Thread tree
              </p>
            </div>
            <nav class="min-h-0 flex-1 overflow-y-auto p-2" aria-label="Codex threads">
              <p :if={@thread_tree == []} class="px-3 py-8 text-center text-xs text-base-content/45">
                No Codex threads yet. CLI hooks, App Server sessions, and JSON jobs will appear here.
              </p>
              <.thread_row
                :for={entry <- @thread_tree}
                entry={entry}
                selected?={entry.thread.thread_id == @selected_thread_id}
              />
            </nav>

            <div class="shrink-0 border-t border-base-300 p-3">
              <.form for={@exec_form} phx-submit="codex:start_exec" class="space-y-2">
                <.input
                  field={@exec_form[:prompt]}
                  type="textarea"
                  label="Read-only background task"
                  placeholder="Review the current changes and summarize risks…"
                  rows="3"
                  class="min-h-20 w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-xs leading-5 text-base-content outline-none transition placeholder:text-base-content/35 focus:border-primary/50 focus:ring-2 focus:ring-primary/10"
                />
                <div class="flex items-center justify-between gap-2">
                  <span class="text-[10px] text-base-content/45">codex exec · sandboxed read-only</span>
                  <button
                    :if={is_nil(@exec_run) or @exec_run.status != :running}
                    type="submit"
                    class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-[11px] font-semibold text-primary-content transition hover:-translate-y-px hover:shadow-sm"
                  >
                    <.icon name="hero-play" class="size-3.5" /> Run
                  </button>
                  <button
                    :if={@exec_run && @exec_run.status == :running}
                    type="button"
                    phx-click="codex:cancel_exec"
                    class="inline-flex items-center gap-1.5 rounded-lg border border-error/35 px-3 py-1.5 text-[11px] font-semibold text-error transition hover:bg-error/10"
                  >
                    <.icon name="hero-stop" class="size-3.5" /> Cancel
                  </button>
                </div>
              </.form>
              <div
                :if={@exec_run}
                class="mt-2 rounded-lg border border-base-300 bg-base-100 px-2.5 py-2 text-[10px] text-base-content/55"
              >
                <span class={["mr-1.5 inline-block size-1.5 rounded-full", run_dot(@exec_run.status)]}></span>
                {humanize(@exec_run.status)} · {short_id(@exec_run.run_id)}
              </div>
            </div>
          </aside>

          <main class="flex min-h-0 min-w-0 flex-col">
            <div class="flex shrink-0 flex-wrap items-center gap-3 border-b border-base-300 px-4 py-3">
              <%= if @selected_thread do %>
                <div class="min-w-0 flex-1">
                  <div class="flex items-center gap-2">
                    <span class={["size-2 rounded-full", status_dot(@selected_thread)]}></span>
                    <h3 class="truncate font-mono text-xs font-semibold text-base-content">
                      {thread_label(@selected_thread)}
                    </h3>
                    <span class="rounded bg-base-200 px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wide text-base-content/50">
                      {humanize(@selected_thread.transport)}
                    </span>
                  </div>
                  <p class="mt-1 truncate text-[10px] text-base-content/45">
                    {@selected_thread.thread_id}
                  </p>
                </div>
                <div class="flex gap-3 text-[10px] text-base-content/55">
                  <span>{compact_number(usage_value(@selected_thread.usage, :input_tokens))} in</span>
                  <span>{compact_number(usage_value(@selected_thread.usage, :output_tokens))} out</span>
                  <span>{compact_number(usage_value(@selected_thread.usage, :total_tokens))} total</span>
                </div>
              <% else %>
                <p class="text-xs text-base-content/50">Select a thread to inspect its timeline.</p>
              <% end %>
            </div>

            <div id="codex-thread-timeline" class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
              <div
                :if={@selected_thread && @timeline == [] && @live_delta == ""}
                class="py-12 text-center text-xs text-base-content/45"
              >
                This thread has no retained lifecycle events yet.
              </div>
              <ol class="relative ml-2 border-l border-base-300 pl-5">
                <.timeline_event :for={event <- @timeline} event={event} />
                <li :if={@live_delta != ""} class="relative pb-5">
                  <span class="absolute -left-[1.64rem] top-1 flex size-3 items-center justify-center rounded-full bg-primary ring-4 ring-base-100"></span>
                  <div class="rounded-xl border border-primary/20 bg-primary/[0.04] p-3 shadow-sm">
                    <div class="mb-2 flex items-center gap-2 text-[10px] font-semibold uppercase tracking-wide text-primary">
                      <span class="size-1.5 animate-pulse rounded-full bg-primary"></span>
                      Streaming response
                    </div>
                    <pre class="whitespace-pre-wrap break-words font-sans text-xs leading-5 text-base-content/80">{@live_delta}</pre>
                  </div>
                </li>
              </ol>
            </div>
          </main>
        </div>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :attention?, :boolean, default: false

  defp metric_chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full border px-2 py-1",
      if(@attention?,
        do: "border-amber-400/35 bg-amber-400/10 text-amber-700 dark:text-amber-300",
        else: "border-base-300 bg-base-100 text-base-content/55"
      )
    ]}>
      <span class="font-medium">{@value}</span><span class="text-[9px] uppercase tracking-wide opacity-70">{@label}</span>
    </span>
    """
  end

  attr :approval, :map, required: true

  defp approval_card(assigns) do
    ~H"""
    <article
      id={"codex-approval-" <> @approval.id}
      class="rounded-xl border border-amber-400/30 bg-base-100 p-3 shadow-sm"
    >
      <div class="flex items-start gap-2">
        <span class="flex size-7 shrink-0 items-center justify-center rounded-lg bg-amber-400/10 text-amber-600 dark:text-amber-300">
          <.icon name={approval_icon(@approval.kind)} class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="text-xs font-semibold text-base-content">{approval_title(@approval.kind)}</p>
          <p class="mt-0.5 truncate font-mono text-[9px] text-base-content/40">
            {short_id(@approval.thread_id)} · {relative_time(@approval.requested_at)}
          </p>
        </div>
      </div>
      <p :if={approval_reason(@approval)} class="mt-2 text-[11px] leading-4 text-base-content/65">
        {approval_reason(@approval)}
      </p>
      <pre
        :if={approval_command(@approval)}
        class="mt-2 max-h-24 overflow-auto rounded-lg bg-zinc-950 px-2.5 py-2 font-mono text-[10px] leading-4 text-zinc-200"
      >{approval_command(@approval)}</pre>
      <div class="mt-3 flex justify-end gap-2">
        <button
          type="button"
          phx-click="codex:resolve_approval"
          phx-value-approval-id={@approval.id}
          phx-value-decision="decline"
          class="rounded-lg border border-base-300 px-2.5 py-1.5 text-[10px] font-semibold text-base-content/65 transition hover:border-error/35 hover:bg-error/10 hover:text-error"
        >
          Reject
        </button>
        <button
          type="button"
          phx-click="codex:resolve_approval"
          phx-value-approval-id={@approval.id}
          phx-value-decision="accept"
          class="rounded-lg bg-emerald-600 px-2.5 py-1.5 text-[10px] font-semibold text-white transition hover:-translate-y-px hover:bg-emerald-500 hover:shadow-sm"
        >
          Approve once
        </button>
      </div>
    </article>
    """
  end

  attr :entry, :map, required: true
  attr :selected?, :boolean, default: false

  defp thread_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="codex:select_thread"
      phx-value-thread-id={@entry.thread.thread_id}
      class={[
        "group mb-0.5 flex w-full items-center gap-2 rounded-lg py-2 pr-2 text-left transition",
        if(@selected?,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/70 hover:bg-base-200"
        )
      ]}
      style={"padding-left: #{0.65 + @entry.depth * 0.85}rem"}
      aria-current={if @selected?, do: "true"}
    >
      <span class={["size-2 shrink-0 rounded-full", status_dot(@entry.thread)]}></span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[11px] font-medium">{thread_label(@entry.thread)}</span>
        <span class="block truncate text-[9px] text-base-content/40">
          {humanize(@entry.thread.status)} · {humanize(@entry.thread.transport)}
        </span>
      </span>
      <span
        :if={waiting?(@entry.thread)}
        class="rounded-full bg-amber-400 px-1.5 py-0.5 text-[8px] font-bold text-amber-950"
      >
        !
      </span>
      <.icon :if={@entry.has_children?} name="hero-chevron-down" class="size-3 text-base-content/30" />
    </button>
    """
  end

  attr :event, :map, required: true

  defp timeline_event(assigns) do
    ~H"""
    <li class="relative pb-5">
      <span class={[
        "absolute -left-[1.72rem] top-1 flex size-4 items-center justify-center rounded-full ring-4 ring-base-100",
        timeline_dot(@event.type)
      ]}>
        <.icon name={timeline_icon(@event.type)} class="size-2.5" />
      </span>
      <article class="rounded-xl border border-base-300 bg-base-100 p-3 shadow-sm transition hover:border-base-content/20">
        <div class="flex items-center justify-between gap-3">
          <p class="text-[11px] font-semibold text-base-content">{event_title(@event)}</p>
          <time class="shrink-0 font-mono text-[9px] text-base-content/35">
            {format_time(@event.occurred_at)}
          </time>
        </div>
        <p
          :if={event_summary(@event)}
          class="mt-1.5 whitespace-pre-wrap break-words text-[11px] leading-5 text-base-content/65"
        >
          {event_summary(@event)}
        </p>
        <div class="mt-2 flex flex-wrap gap-1 text-[8px] uppercase tracking-wide text-base-content/40">
          <span class="rounded bg-base-200 px-1.5 py-0.5">{humanize(@event.transport)}</span>
          <span :if={@event.turn_id} class="rounded bg-base-200 px-1.5 py-0.5">turn {short_id(
            @event.turn_id
          )}</span>
          <span :if={@event.item_id} class="rounded bg-base-200 px-1.5 py-0.5">item {short_id(
            @event.item_id
          )}</span>
        </div>
      </article>
    </li>
    """
  end

  defp thread_tree(threads) do
    by_parent = Enum.group_by(threads, & &1.parent_thread_id)
    ids = MapSet.new(threads, & &1.thread_id)

    roots =
      Enum.filter(
        threads,
        &(is_nil(&1.parent_thread_id) or not MapSet.member?(ids, &1.parent_thread_id))
      )

    roots
    |> Enum.flat_map(&flatten_thread(&1, by_parent, 0, MapSet.new()))
  end

  defp flatten_thread(thread, by_parent, depth, seen) do
    if MapSet.member?(seen, thread.thread_id) do
      []
    else
      seen = MapSet.put(seen, thread.thread_id)
      children = Map.get(by_parent, thread.thread_id, [])
      entry = %{thread: thread, depth: depth, has_children?: children != []}
      [entry | Enum.flat_map(children, &flatten_thread(&1, by_parent, depth + 1, seen))]
    end
  end

  defp selected_thread(threads, id), do: Enum.find(threads, &(&1.thread_id == id))

  defp usage_totals(threads) do
    Enum.reduce(threads, %{input_tokens: 0, output_tokens: 0, total_tokens: 0}, fn thread, acc ->
      %{
        input_tokens: acc.input_tokens + usage_value(thread.usage, :input_tokens),
        output_tokens: acc.output_tokens + usage_value(thread.usage, :output_tokens),
        total_tokens: acc.total_tokens + usage_value(thread.usage, :total_tokens)
      }
    end)
  end

  defp usage_value(usage, key) when is_map(usage) do
    total = Map.get(usage, :total) || Map.get(usage, "total") || usage
    value = Map.get(total, key) || Map.get(total, Atom.to_string(key))
    if is_integer(value), do: value, else: 0
  end

  defp usage_value(_usage, _key), do: 0

  defp waiting?(thread),
    do:
      Enum.any?(thread.active_flags || [], &(&1 in [:waiting_on_approval, "waiting_on_approval"]))

  defp status_dot(thread) do
    cond do
      waiting?(thread) -> "bg-amber-400"
      thread.status in ["active", :active] -> "bg-emerald-500"
      thread.status in ["failed", :failed, "error", :error] -> "bg-error"
      true -> "bg-base-content/25"
    end
  end

  defp thread_label(thread) do
    thread.agent_nickname || thread.agent_role || thread.preview ||
      "Thread #{short_id(thread.thread_id)}"
  end

  defp approval_icon("command_execution"), do: "hero-command-line"
  defp approval_icon("file_change"), do: "hero-document-text"
  defp approval_icon(_kind), do: "hero-shield-check"
  defp approval_title("command_execution"), do: "Command execution"
  defp approval_title("file_change"), do: "File changes"
  defp approval_title("permissions"), do: "Additional permissions"
  defp approval_title(kind), do: humanize(kind)

  defp approval_reason(approval), do: value(approval.payload, "reason")

  defp approval_command(approval),
    do: value(approval.payload, "command") || value(approval.payload, "grant_root")

  defp event_title(event), do: event.type |> humanize()

  defp event_summary(event) do
    payload = event.payload

    (value(payload, "text") || value(payload, "command") || value(payload, "message") ||
       value(payload, "last_message") || value(payload, "reason") || value(payload, "error") ||
       event_status(payload))
    |> printable()
  end

  defp event_status(payload), do: value(payload, "status")
  defp printable(nil), do: nil
  defp printable(value) when is_binary(value), do: value
  defp printable(value) when is_atom(value), do: humanize(value)
  defp printable(value) when is_map(value), do: inspect(value, pretty: true, limit: 20)
  defp printable(value), do: to_string(value)

  defp timeline_icon(type) when type in [:turn_failed, :error], do: "hero-exclamation-triangle"
  defp timeline_icon(:approval_requested), do: "hero-shield-exclamation"
  defp timeline_icon(:approval_resolved), do: "hero-shield-check"

  defp timeline_icon(type) when type in [:subagent_started, :subagent_stopped],
    do: "hero-user-group"

  defp timeline_icon(:usage_updated), do: "hero-chart-bar-square"
  defp timeline_icon(_type), do: "hero-bolt"

  defp timeline_dot(type) when type in [:turn_failed, :error], do: "bg-error text-error-content"
  defp timeline_dot(:approval_requested), do: "bg-amber-400 text-amber-950"
  defp timeline_dot(:approval_resolved), do: "bg-emerald-500 text-white"
  defp timeline_dot(_type), do: "bg-base-300 text-base-content/55"

  defp run_dot(:running), do: "animate-pulse bg-primary"
  defp run_dot(:succeeded), do: "bg-emerald-500"
  defp run_dot(_status), do: "bg-error"

  defp compact_number(value) when value >= 1_000_000,
    do: :erlang.float_to_binary(value / 1_000_000, decimals: 1) <> "m"

  defp compact_number(value) when value >= 1_000,
    do: :erlang.float_to_binary(value / 1_000, decimals: 1) <> "k"

  defp compact_number(value), do: to_string(value || 0)

  defp humanize(nil), do: "Unknown"
  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value) do
    value |> String.replace(["_", "."], " ") |> String.capitalize()
  end

  defp short_id(nil), do: "—"
  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_id(value), do: value |> to_string() |> short_id()

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      case safe_existing_atom(key) do
        nil -> nil
        atom -> Map.get(map, atom)
      end
  end

  defp value(_map, _key), do: nil

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M:%S")
  defp format_time(_datetime), do: ""

  defp relative_time(%DateTime{} = datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 60 -> "now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_time(_datetime), do: ""
end
