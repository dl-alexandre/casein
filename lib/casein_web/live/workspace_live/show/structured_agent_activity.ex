defmodule CaseinWeb.WorkspaceLive.Show.StructuredAgentActivity do
  @moduledoc false

  use CaseinWeb, :html

  attr :loaded?, :boolean, required: true
  attr :threads, :list, required: true
  attr :selected_thread_id, :string, default: nil
  attr :timeline, :list, required: true
  attr :live_delta, :string, default: ""
  attr :error, :string, default: nil

  def structured_agent_activity(assigns) do
    assigns =
      assigns
      |> assign(:thread_tree, thread_tree(assigns.threads))
      |> assign(:selected_thread, selected_thread(assigns.threads, assigns.selected_thread_id))
      |> assign(:usage_totals, usage_totals(assigns.threads))

    ~H"""
    <details
      id="structured-agent-activity"
      class="mb-3 overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-sm"
    >
      <summary class="flex cursor-pointer list-none items-center gap-3 bg-base-200/45 px-3 py-2.5 [&::-webkit-details-marker]:hidden">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
          <.icon name="hero-bolt" class="size-4" />
        </span>
        <span class="min-w-0 flex-1">
          <span class="block text-sm font-semibold text-base-content">Structured agent activity</span>
          <span class="block truncate text-density-body text-base-content/55">
            Codex lifecycle, subagent, and usage events
          </span>
        </span>
        <span class="hidden items-center gap-1.5 text-density-label text-base-content/55 sm:flex">
          <.metric label="threads" value={length(@threads)} />
          <.metric label="tokens" value={compact_number(@usage_totals.total_tokens)} />
        </span>
        <.icon name="hero-chevron-down" class="size-4 text-base-content/40" />
      </summary>

      <div :if={@error} class="border-t border-error/20 bg-error/10 px-3 py-2 text-xs text-error">
        {@error}
      </div>

      <div
        :if={not @loaded?}
        class="border-t border-base-300 px-3 py-6 text-center text-xs text-base-content/50"
      >
        Loading structured activity…
      </div>

      <div
        :if={@loaded?}
        class="flex flex-wrap items-center gap-3 border-t border-base-300 bg-base-200/20 px-3 py-2 text-density-label text-base-content/55"
      >
        <span>{compact_number(@usage_totals.input_tokens)} input</span>
        <span>{compact_number(@usage_totals.output_tokens)} output</span>
        <span>{compact_number(@usage_totals.total_tokens)} total</span>
        <button
          id="structured-agent-refresh-button"
          type="button"
          phx-click="codex:refresh"
          class="ml-auto inline-flex size-7 items-center justify-center rounded-lg border border-base-300 bg-base-100 text-base-content/60 transition hover:border-primary/35 hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/30"
          title="Refresh structured agent activity"
          aria-label="Refresh structured agent activity"
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
        </button>
      </div>

      <div
        :if={@loaded?}
        class="grid min-h-56 border-t border-base-300 md:grid-cols-[17rem_minmax(0,1fr)]"
      >
        <nav
          class="max-h-80 overflow-y-auto border-b border-base-300 bg-base-200/20 p-2 md:border-r md:border-b-0"
          aria-label="Structured agent threads"
        >
          <p :if={@thread_tree == []} class="px-3 py-8 text-center text-xs text-base-content/45">
            No structured agent events have been retained for this workspace.
          </p>
          <.thread_row
            :for={entry <- @thread_tree}
            entry={entry}
            selected?={entry.thread.thread_id == @selected_thread_id}
          />
        </nav>

        <section class="flex min-h-56 min-w-0 flex-col">
          <div class="flex shrink-0 flex-wrap items-center gap-2 border-b border-base-300 px-3 py-2">
            <%= if @selected_thread do %>
              <span class={["size-2 rounded-full", status_dot(@selected_thread)]}></span>
              <span class="min-w-0 flex-1">
                <span class="block truncate font-mono text-xs font-semibold text-base-content">
                  {thread_label(@selected_thread)}
                </span>
                <span
                  class="block truncate font-mono text-density-badge text-base-content/40"
                  title={@selected_thread.thread_id}
                >
                  {@selected_thread.thread_id}
                </span>
              </span>
              <span class="rounded bg-base-200 px-1.5 py-density-badge text-density-badge font-semibold uppercase tracking-wide text-base-content/50">
                {humanize(@selected_thread.transport)}
              </span>
              <span class="hidden items-center gap-2 text-density-label text-base-content/50 sm:flex">
                <span>{compact_number(usage_value(@selected_thread.usage, :input_tokens))} in</span>
                <span>{compact_number(usage_value(@selected_thread.usage, :output_tokens))} out</span>
                <span>{compact_number(usage_value(@selected_thread.usage, :total_tokens))} total</span>
              </span>
            <% else %>
              <p class="text-xs text-base-content/50">Select a thread to inspect its events.</p>
            <% end %>
          </div>

          <div class="max-h-80 min-h-0 flex-1 overflow-y-auto px-4 py-3">
            <div
              :if={@selected_thread && @timeline == [] && @live_delta == ""}
              class="py-8 text-center text-xs text-base-content/45"
            >
              This thread has no retained lifecycle events yet.
            </div>
            <ol class="relative ml-2 border-l border-base-300 pl-5">
              <.timeline_event :for={event <- @timeline} event={event} />
              <li :if={@live_delta != ""} class="relative pb-4">
                <span class="absolute -left-[1.47rem] top-1 size-2.5 rounded-full bg-primary ring-4 ring-base-100"></span>
                <div class="rounded-lg border border-primary/20 bg-primary/[0.04] p-3">
                  <div class="mb-1.5 flex items-center gap-2 text-density-label font-semibold uppercase tracking-wide text-primary">
                    <span class="size-1.5 animate-pulse rounded-full bg-primary"></span> Streaming
                  </div>
                  <pre class="whitespace-pre-wrap break-words font-sans text-xs leading-5 text-base-content/80">{@live_delta}</pre>
                </div>
              </li>
            </ol>
          </div>
        </section>
      </div>
    </details>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp metric(assigns) do
    ~H"""
    <span class="rounded-full border border-base-300 bg-base-100 px-2 py-1">
      <span class="font-semibold">{@value}</span> {@label}
    </span>
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
        <span class="block truncate text-density-body font-medium">{thread_label(@entry.thread)}</span>
        <span class="block truncate text-density-badge text-base-content/40">
          {humanize(@entry.thread.status)} · {humanize(@entry.thread.transport)}
        </span>
      </span>
      <span
        :if={waiting?(@entry.thread)}
        class="rounded-full bg-status-warning px-1.5 py-density-micro text-density-micro font-bold text-status-warning-fg"
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
    <li class="relative pb-4">
      <span class={[
        "absolute -left-[1.55rem] top-1 flex size-3.5 items-center justify-center rounded-full ring-4 ring-base-100",
        timeline_dot(@event.type)
      ]}>
        <.icon name={timeline_icon(@event.type)} class="size-2" />
      </span>
      <article class="rounded-lg border border-base-300 bg-base-100 p-2.5 transition hover:border-base-content/20">
        <div class="flex items-center justify-between gap-3">
          <p class="text-density-body font-semibold text-base-content">{event_title(@event)}</p>
          <time class="shrink-0 font-mono text-density-badge text-base-content/35">
            {format_time(@event.occurred_at)}
          </time>
        </div>
        <p
          :if={event_summary(@event)}
          class="mt-1 whitespace-pre-wrap break-words text-density-body leading-5 text-base-content/65"
        >
          {event_summary(@event)}
        </p>
        <div class="mt-2 flex flex-wrap gap-1 text-density-micro uppercase tracking-wide text-base-content/40">
          <span class="rounded bg-base-200 px-1.5 py-0.5">{humanize(@event.transport)}</span>
          <span :if={@event.turn_id} class="rounded bg-base-200 px-1.5 py-0.5">
            turn {short_id(@event.turn_id)}
          </span>
          <span :if={@event.item_id} class="rounded bg-base-200 px-1.5 py-0.5">
            item {short_id(@event.item_id)}
          </span>
        </div>
      </article>
    </li>
    """
  end

  defp thread_tree(threads) do
    by_parent = Enum.group_by(threads, & &1.parent_thread_id)
    ids = MapSet.new(threads, & &1.thread_id)

    threads
    |> Enum.filter(&(is_nil(&1.parent_thread_id) or not MapSet.member?(ids, &1.parent_thread_id)))
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
      Enum.any?(
        thread.active_flags || [],
        &(&1 in [
            :waiting_on_approval,
            "waiting_on_approval",
            :waiting_on_user_input,
            "waiting_on_user_input"
          ])
      )

  defp status_dot(thread) do
    cond do
      waiting?(thread) -> "bg-status-warning"
      thread.status in ["active", :active] -> "bg-status-ok"
      thread.status in ["failed", :failed, "error", :error] -> "bg-error"
      true -> "bg-base-content/25"
    end
  end

  defp thread_label(thread) do
    thread.agent_nickname || thread.agent_role || thread.preview ||
      "Thread #{short_id(thread.thread_id)}"
  end

  defp event_title(event), do: humanize(event.type)

  defp event_summary(event) do
    payload = event.payload

    (value(payload, "text") || value(payload, "command") || value(payload, "message") ||
       value(payload, "last_message") || value(payload, "reason") || value(payload, "error") ||
       value(payload, "status"))
    |> printable()
  end

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
  defp timeline_dot(:approval_requested), do: "bg-status-warning text-status-warning-content"
  defp timeline_dot(:approval_resolved), do: "bg-status-ok text-white"
  defp timeline_dot(_type), do: "bg-base-300 text-base-content/55"

  defp compact_number(value) when value >= 1_000_000,
    do: :erlang.float_to_binary(value / 1_000_000, decimals: 1) <> "m"

  defp compact_number(value) when value >= 1_000,
    do: :erlang.float_to_binary(value / 1_000, decimals: 1) <> "k"

  defp compact_number(value), do: to_string(value || 0)

  defp humanize(nil), do: "Unknown"
  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value),
    do: value |> String.replace(["_", "."], " ") |> String.capitalize()

  defp short_id(nil), do: "—"
  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_id(value), do: value |> to_string() |> short_id()

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || existing_atom_value(map, key)
  end

  defp value(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M:%S")
  defp format_time(_datetime), do: ""
end
