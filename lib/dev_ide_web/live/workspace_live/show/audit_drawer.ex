defmodule DevIdeWeb.WorkspaceLive.Show.AuditDrawer do
  @moduledoc false

  use DevIdeWeb, :html

  attr :audit_drawer_open, :boolean, required: true
  attr :audit_events_count, :integer, required: true
  attr :audit_ledger_count, :integer, required: true
  attr :audit_window_filter, :string, default: ""
  attr :workspace, :map, required: true
  attr :streams, :map, required: true

  attr :target, :any,
    default: nil,
    doc: "phx-target for refresh/filter events; toggle/close stay on the root LV (hub state)"

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
            <p class="text-[11px] text-zinc-500 font-mono">
              {@audit_events_count} events · {@audit_ledger_count} ledger · workspace {@workspace.name}
            </p>
          </div>
          <div class="flex items-center gap-1">
            <button
              phx-click="audit_drawer:refresh"
              phx-target={@target}
              class="text-[11px] border rounded px-2 py-0.5 hover:bg-zinc-50"
              title="refresh audit"
            >
              ↻
            </button>
            <button
              phx-click="audit_drawer:close"
              class="text-[11px] border rounded px-2 py-0.5 hover:bg-zinc-50"
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
            class="w-full rounded border border-zinc-200 px-2 py-1 font-mono text-[11px] text-zinc-700 placeholder:text-zinc-400 focus:border-zinc-400 focus:outline-none"
            autocomplete="off"
          />
        </div>
        <div class="flex-1 overflow-auto px-3 py-2 font-mono text-[11px] leading-relaxed">
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
                <%= if run_id = audit_run_id(e) do %>
                  <button
                    id={"audit-open-run-#{dom_fragment(run_id)}-#{dom_fragment(e.id)}"}
                    phx-click="run_ledger:open"
                    phx-value-id={run_id}
                    class="ml-auto shrink-0 rounded border px-1 py-0.5 text-[10px] text-zinc-600 hover:bg-zinc-50"
                    title="open run timeline"
                  >
                    run
                  </button>
                <% end %>
              </li>
            <% end %>
          </ol>
        </div>
        <footer class="px-3 py-2 border-t text-[10px] text-zinc-500 font-mono">
          newest first · capped at 50 · time-ordered stream (product.md §9.4)
        </footer>
      </aside>
    </div>
    """
  end

  def deny_count(events), do: Enum.count(events, fn e -> e.decision == :deny end)

  def ledger_event_count(events),
    do: Enum.count(events, &DevIDE.Runs.Ledger.ledger_event?/1)

  def audit_dot_class(%{decision: :deny}), do: "bg-red-600"
  def audit_dot_class(%{decision: :allow}), do: "bg-green-600"
  def audit_dot_class(%{action: "workspace.mode_set"}), do: "bg-amber-500"
  def audit_dot_class(_), do: "bg-zinc-400"

  def audit_verb_class(%{decision: :deny}), do: "text-red-700"
  def audit_verb_class(%{decision: :allow}), do: "text-green-700"
  def audit_verb_class(%{action: "workspace.mode_set"}), do: "text-amber-700"
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

  defp dom_fragment(value) when is_binary(value),
    do: String.replace(value, ~r/[^a-zA-Z0-9_-]/, "-")

  defp dom_fragment(value), do: value |> to_string() |> dom_fragment()
end
