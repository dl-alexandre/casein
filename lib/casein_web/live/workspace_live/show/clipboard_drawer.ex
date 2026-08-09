defmodule CaseinWeb.WorkspaceLive.Show.ClipboardDrawer do
  @moduledoc false

  use CaseinWeb, :html

  attr :open, :boolean, required: true
  attr :entries, :list, default: []
  attr :count, :integer, default: 0

  def clipboard_drawer(assigns) do
    ~H"""
    <div :if={@open} id="clipboard-drawer" class="fixed inset-0 z-40 pointer-events-none">
      <div class="absolute inset-0 bg-black/20 pointer-events-auto" phx-click="clipboard:close"></div>
      <aside
        class="absolute right-0 top-0 bottom-0 flex w-[420px] max-w-[92vw] flex-col border-l bg-white pointer-events-auto shadow-xl"
        role="complementary"
        aria-label="Clipboard drawer"
      >
        <header class="flex items-center justify-between border-b px-4 py-3">
          <div>
            <h2 class="text-sm font-semibold tracking-tight text-zinc-950">Clipboard</h2>
            <p id="clipboard-drawer-count" class="font-mono text-density-body text-zinc-500">
              {@count} recent {if @count == 1, do: "copy", else: "copies"} from agents
            </p>
          </div>
          <div class="flex items-center gap-1">
            <button
              :if={@count > 0}
              id="clipboard-clear"
              phx-click="clipboard:clear"
              class="rounded border px-2 py-density-body text-density-body text-zinc-700 hover:bg-zinc-50"
              title="Forget every copy in this list"
            >
              clear
            </button>
            <button
              id="clipboard-drawer-close"
              phx-click="clipboard:close"
              class="rounded border px-2 py-density-body text-density-body hover:bg-zinc-50"
              title="Close"
            >
              ×
            </button>
          </div>
        </header>

        <div class="min-h-0 flex-1 space-y-2 overflow-auto px-3 py-3">
          <p
            :if={@entries == []}
            id="clipboard-empty"
            class="px-1 py-6 text-center text-xs text-zinc-500"
          >
            Nothing copied yet. When an agent copies something it lands here, so you can pick it up
            even if the copy prompt was missed.
          </p>

          <article
            :for={entry <- @entries}
            id={"clipboard-entry-" <> entry.id}
            class="rounded border border-zinc-200 p-2 shadow-sm"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="truncate font-mono text-density-body text-zinc-500">
                {source_label(entry)} · {relative_time(entry.inserted_at)}
              </span>
              <div class="flex flex-none items-center gap-1">
                <button
                  id={"clipboard-copy-" <> entry.id}
                  type="button"
                  phx-hook="CopyText"
                  data-copy-text={entry.text}
                  class="inline-flex items-center gap-1 rounded border border-zinc-300 px-2 py-1 text-xs font-medium hover:bg-zinc-50 data-[copied]:border-status-ok data-[copied]:text-status-ok-fg pointer-coarse:px-3 pointer-coarse:py-1.5"
                >
                  <.icon name="hero-clipboard" class="size-3.5" /> Copy
                </button>
                <button
                  id={"clipboard-share-" <> entry.id}
                  type="button"
                  phx-hook="ShareText"
                  data-share-text={entry.text}
                  hidden
                  class="inline-flex items-center gap-1 rounded border border-zinc-300 px-2 py-1 text-xs font-medium hover:bg-zinc-50 pointer-coarse:px-3 pointer-coarse:py-1.5"
                >
                  <.icon name="hero-share" class="size-3.5" /> Share
                </button>
              </div>
            </div>

            <pre class="mt-1.5 max-h-32 overflow-auto whitespace-pre-wrap break-all rounded bg-zinc-50 p-1.5 font-mono text-density-body text-zinc-800">{preview(entry.text)}</pre>

            <p :if={entry.truncated?} class="mt-1 text-density-label text-status-warning-fg">
              Truncated — this copy was larger than the retained limit.
            </p>
          </article>
        </div>
      </aside>
    </div>
    """
  end

  defp source_label(%{pane_label: label}) when is_binary(label), do: label
  defp source_label(%{pane_id: pane_id}) when is_binary(pane_id), do: pane_id
  defp source_label(_entry), do: "terminal"

  @preview_chars 400

  defp preview(text) do
    if String.length(text) > @preview_chars do
      String.slice(text, 0, @preview_chars) <> "…"
    else
      text
    end
  end

  defp relative_time(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      seconds when seconds < 5 -> "just now"
      seconds when seconds < 60 -> "#{seconds}s ago"
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_time(_), do: ""
end
