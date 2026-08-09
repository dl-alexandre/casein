defmodule CaseinWeb.WorkspaceLive.Show.AuditDrawer do
  @moduledoc false

  use CaseinWeb, :html

  attr :audit_drawer_open, :boolean, required: true
  attr :audit_events_count, :integer, required: true
  attr :audit_ledger_count, :integer, required: true
  attr :audit_window_filter, :string, default: ""
  attr :workspace, :map, required: true
  attr :streams, :map, required: true

  attr :target, :any,
    default: nil,
    doc: "phx-target for refresh/filter events; toggle/close stay on the root LV (hub state)"

  attr :audit_trace, :map,
    default: nil,
    doc: "when set (%{correlation_id, events}), renders the drilled-in causal chain panel"

  def audit_drawer(assigns) do
    ~H"""
    <div
      :if={@audit_drawer_open}
      class="fixed inset-0 z-40 pointer-events-none"
      aria-hidden="false"
    >
      <div
        class="absolute inset-0 bg-black/20 pointer-events-auto"
        phx-click="audit_drawer:close"
      >
      </div>
      <aside
        class="absolute right-0 top-0 bottom-0 w-[380px] bg-white border-l shadow-xl pointer-events-auto flex flex-col"
        role="complementary"
        aria-label="Evidence drawer"
      >
        <header class="flex items-center justify-between px-4 py-3 border-b">
          <div>
            <h2 class="text-sm font-semibold tracking-tight">Evidence</h2>
            <p class="text-density-body text-zinc-500 font-mono">
              {@audit_events_count} events · {@audit_ledger_count} ledger · workspace {@workspace.name}
            </p>
          </div>
          <div class="flex items-center gap-1">
            <button
              phx-click="audit_drawer:refresh"
              phx-target={@target}
              class="text-density-body border rounded px-2 py-density-body hover:bg-zinc-50"
              title="refresh audit"
            >
              ↻
            </button>
            <button
              phx-click="audit_drawer:close"
              class="text-density-body border rounded px-2 py-density-body hover:bg-zinc-50"
              title="close (esc)"
            >
              ×
            </button>
          </div>
        </header>
        <div class="px-3 py-2 border-b">
          <label class="sr-only" for="audit-window-filter">Filter by tmux window</label>
          <input
            id="audit-window-filter"
            type="search"
            name="filter"
            value={@audit_window_filter}
            phx-change="audit_drawer:filter_window"
            phx-target={@target}
            phx-debounce="300"
            placeholder="Filter by window name or id…"
            class="w-full rounded border border-zinc-200 px-2 py-1 font-mono text-density-body text-zinc-700 placeholder:text-zinc-400 focus:border-zinc-400 focus:outline-none"
            autocomplete="off"
          />
        </div>
        <div class="flex-1 overflow-auto px-3 py-2 font-mono text-density-body leading-relaxed">
          <ol id="audit-events" phx-update="stream" class="space-y-1.5">
            <li id="audit-events-empty" class="hidden only:block text-zinc-400 italic">
              no events recorded yet
            </li>
            <%= for {dom_id, e} <- @streams.audit_events do %>
              <li id={dom_id} class="flex gap-2 items-baseline">
                <span class={"inline-block w-1.5 h-1.5 rounded-full mt-1.5 shrink-0 " <> audit_dot_class(e)}></span>
                <span class="text-zinc-400 shrink-0">
                  {Calendar.strftime(e.inserted_at, "%H:%M:%S")}
                </span>
                <span class={"shrink-0 font-medium " <> audit_verb_class(e)}>
                  {audit_verb(e)}
                </span>
                <span class="text-zinc-700 break-all">
                  {audit_detail(e)}
                </span>
                <span class="ml-auto flex gap-1 shrink-0">
                  <%= if cid = audit_correlation_id(e) do %>
                    <button
                      id={"audit-trace-#{dom_fragment(cid)}-#{dom_fragment(e.id)}"}
                      phx-click="audit_drawer:trace"
                      phx-value-correlation={cid}
                      phx-target={@target}
                      class="rounded border px-1 py-density-label text-density-label text-indigo-600 hover:bg-indigo-50"
                      title="show causal chain"
                    >
                      trace
                    </button>
                  <% end %>
                  <%= if run_id = audit_run_id(e) do %>
                    <button
                      id={"audit-open-run-#{dom_fragment(run_id)}-#{dom_fragment(e.id)}"}
                      phx-click="run_ledger:open"
                      phx-value-id={run_id}
                      class="rounded border px-1 py-density-label text-density-label text-zinc-600 hover:bg-zinc-50"
                      title="open run timeline"
                    >
                      run
                    </button>
                  <% end %>
                </span>
              </li>
            <% end %>
          </ol>
        </div>
        <%= if @audit_trace do %>
          <section
            id="audit-causal-chain"
            class="border-t bg-indigo-50/60 px-3 py-2 text-density-body max-h-48 overflow-y-auto"
          >
            <div class="flex items-center justify-between mb-1">
              <span class="font-medium text-indigo-700">
                causal chain · {length(@audit_trace.events)} event(s)
              </span>
              <button
                phx-click="audit_drawer:trace_close"
                phx-target={@target}
                class="rounded border px-1 py-density-label text-density-label text-zinc-600 hover:bg-white"
                title="close causal chain"
              >
                close
              </button>
            </div>
            <%= if @audit_trace.events == [] do %>
              <p class="text-zinc-400 italic">no linked events</p>
            <% else %>
              <ol class="space-y-0.5">
                <%= for ce <- @audit_trace.events do %>
                  <li class="flex gap-2 items-baseline">
                    <span class="text-zinc-400 shrink-0">
                      {Calendar.strftime(ce.inserted_at, "%H:%M:%S")}
                    </span>
                    <span class={"shrink-0 font-medium " <> audit_verb_class(ce)}>
                      {audit_verb(ce)}
                    </span>
                    <span class="text-zinc-700 break-all">{audit_detail(ce)}</span>
                  </li>
                <% end %>
              </ol>
            <% end %>
            <div class="mt-1 text-density-label text-zinc-500 font-mono">
              correlation {String.slice(@audit_trace.correlation_id, 0, 12)}… · causal order
            </div>
          </section>
        <% end %>
        <footer class="px-3 py-2 border-t text-density-label text-zinc-500 font-mono">
          newest first · capped at 50 · time-ordered stream (product.md §9.4)
        </footer>
      </aside>
    </div>
    """
  end

  def deny_count(events), do: Enum.count(events, fn e -> e.decision == :deny end)

  def ledger_event_count(events),
    do: Enum.count(events, &Casein.Runs.Ledger.ledger_event?/1)

  def audit_dot_class(%{decision: :deny}), do: "bg-status-danger"
  def audit_dot_class(%{decision: :allow}), do: "bg-status-ok"
  def audit_dot_class(%{action: "workspace.mode_set"}), do: "bg-status-warning"
  def audit_dot_class(_), do: "bg-zinc-400"

  def audit_verb_class(%{decision: :deny}), do: "text-status-danger-fg"
  def audit_verb_class(%{decision: :allow}), do: "text-status-ok-fg"
  def audit_verb_class(%{action: "workspace.mode_set"}), do: "text-status-warning-fg"
  def audit_verb_class(_), do: "text-zinc-600"

  def audit_verb(%{decision: :deny}), do: "deny"
  def audit_verb(%{decision: :allow}), do: "allow"
  def audit_verb(%{action: "workspace.mode_set"}), do: "mode"
  def audit_verb(%{action: action}), do: action |> String.split(".") |> List.last()

  def audit_detail(%{action: action, target_ref: ref, reason: reason} = event) do
    base = action

    base =
      cond do
        ref && ref != "" -> "#{base} · #{ref}"
        true -> base
      end

    base =
      case audit_window_label(event) do
        label when is_binary(label) and label != "" -> "#{base} · win:#{label}"
        _ -> base
      end

    cond do
      reason -> "#{base} · #{Atom.to_string(reason)}"
      true -> base
    end
  end

  defp audit_window_label(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "tmux_window_name") || Map.get(metadata, :tmux_window_name) ||
      Map.get(metadata, "tmux_window_id") || Map.get(metadata, :tmux_window_id)
  end

  defp audit_window_label(_), do: nil

  defp audit_run_id(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "run_id") || Map.get(metadata, :run_id)
  end

  defp audit_run_id(_), do: nil

  # A correlation id means this event belongs to a causal chain worth drilling
  # into (stamped by Casein.Signals.Context at entry points / MCP tool calls).
  defp audit_correlation_id(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "correlation_id") || Map.get(metadata, :correlation_id) do
      cid when is_binary(cid) and cid != "" -> cid
      _ -> nil
    end
  end

  defp audit_correlation_id(_), do: nil

  defp dom_fragment(value) when is_binary(value),
    do: String.replace(value, ~r/[^a-zA-Z0-9_-]/, "-")

  defp dom_fragment(value), do: value |> to_string() |> dom_fragment()
end
