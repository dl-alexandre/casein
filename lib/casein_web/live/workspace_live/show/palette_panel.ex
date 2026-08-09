defmodule CaseinWeb.WorkspaceLive.Show.PalettePanel do
  @moduledoc false

  use CaseinWeb, :html
  import Phoenix.Component

  # Ordered category tabs shown in the palette. `:all` is always first so the
  # user can broaden out of any screen-derived default.
  @palette_categories [:all, :files, :commands, :tmux, :agents, :preview, :view, :actions]

  @doc false
  def palette_categories, do: @palette_categories

  @doc false
  def palette_category_label(:all), do: "all"
  def palette_category_label(:files), do: "files"
  def palette_category_label(:commands), do: "commands"
  def palette_category_label(:tmux), do: "tmux"
  def palette_category_label(:agents), do: "agents"
  def palette_category_label(:preview), do: "preview"
  def palette_category_label(:view), do: "view"
  def palette_category_label(:actions), do: "actions"

  def palette_overlay(assigns) do
    meta = palette_meta(assigns[:palette_result_meta], assigns[:palette_items] || [])

    assigns =
      assigns
      |> Phoenix.Component.assign(
        :palette_selected_id,
        palette_selected_id(assigns[:palette_items], assigns[:palette_selected_idx])
      )
      |> Phoenix.Component.assign(:palette_meta, meta)
      |> Phoenix.Component.assign(:frequent_ids, meta.frequent_ids)

    ~H"""
    <%= if @palette_open do %>
      <%!--
        Narrow layout (width) vs touch targets (pointer-coarse) stay separate:
        max-sm collapses category chrome and row meta; pointer-coarse only
        grows hit areas. Tab/Shift+Tab category cycling lives in PaletteHook
        (pushEvent), not DOM focus on these buttons — inactive tabs may be
        visually hidden below sm without killing keyboard cycling.
      --%>
      <div
        id="palette-modal"
        class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 pt-[max(0.5rem,min(6rem,10svh))] sm:pt-16 md:pt-24"
        phx-click="palette:close"
      >
        <div
          class="flex w-full max-w-[calc(100vw-1rem)] flex-col rounded border border-base-300 bg-base-100 text-base-content shadow-2xl sm:w-[640px] sm:max-w-[90vw]"
          phx-click-away="palette:close"
        >
          <.form
            for={%{}}
            id="palette-form"
            phx-change="palette:query"
            phx-submit="palette:execute"
            class="border-b border-base-300 p-2"
          >
            <%!--
              `phx-mounted` runs the focus command every time this input
              is inserted into the DOM (each time the palette opens),
              which `autofocus` alone does not — the user usually opens
              the palette while focus is in the terminal/PTY, so we
              have to take it explicitly.
            --%>
            <input
              id="palette-query"
              name="query"
              value={@palette_query}
              autocomplete="off"
              spellcheck="false"
              placeholder="Search sessions, windows, files, commands…"
              phx-debounce="150"
              phx-mounted={Phoenix.LiveView.JS.focus()}
              class="w-full bg-transparent px-2 py-1.5 text-sm outline-none placeholder:text-base-content/40 pointer-coarse:py-2.5"
            />
            <%!--
              The hidden _selected_id field carries the currently
              highlighted item to the server when the form submits
              (Enter). Falls back to the top item if nothing is
              explicitly selected.
            --%>
            <input type="hidden" name="_selected_id" value={@palette_selected_id} />
          </.form>
          <%!--
            Category tabs. The active screen sets the default (see
            default_palette_category/1); Tab / Shift+Tab cycle them from the
            PaletteHook, and clicking selects directly. ":all" is always first.

            Below `sm`, inactive tabs are visually collapsed so the row cannot
            overflow; every category button stays in the DOM and the hook still
            cycles via palette:category — keyboard reachability is unchanged.
          --%>
          <div
            id="palette-categories"
            class="flex items-center gap-1 overflow-x-auto border-b border-base-300 px-2 py-1 text-xs"
          >
            <%= for cat <- palette_categories() do %>
              <button
                type="button"
                phx-click="palette:category"
                phx-value-category={Atom.to_string(cat)}
                class={[
                  "shrink-0 rounded px-2 py-0.5 font-mono lowercase",
                  "pointer-coarse:min-h-11 pointer-coarse:min-w-11 pointer-coarse:px-3 pointer-coarse:py-2",
                  if(cat == (@palette_category || :all),
                    do: "bg-primary/20 text-base-content",
                    else: "text-base-content/55 hover:bg-base-200 max-sm:hidden"
                  )
                ]}
              >
                {palette_category_label(cat)}
              </button>
            <% end %>
            <span class="ml-auto hidden shrink-0 font-mono text-density-label text-base-content/45 max-sm:inline">
              ⇥ cycle
            </span>
          </div>
          <ul
            id="palette-results"
            class="max-h-[min(60vh,calc(100dvh-11rem))] overflow-auto text-sm sm:max-h-[60vh]"
          >
            <%= if @palette_items == [] do %>
              <li class="list-none px-2 py-1">
                <CaseinWeb.WorkspaceLive.Show.UI.panel_state
                  id="palette-no-matches"
                  kind={:empty}
                  message="No matches."
                  class="border-0 bg-transparent px-1 py-1 text-base-content/60"
                />
              </li>
            <% else %>
              <%= for {item, idx} <- Enum.with_index(@palette_items) do %>
                <% selected? = idx == (@palette_selected_idx || 0) %>
                <% frequent? = MapSet.member?(@frequent_ids, item.id) %>
                <li
                  id={"palette-item-" <> Integer.to_string(idx)}
                  data-palette-idx={idx}
                  data-palette-kind={to_string(item.kind)}
                  data-palette-frequent={if(frequent?, do: "true", else: "false")}
                  class={
                    [
                      # Truncation priority (stated, not content-dependent):
                      #   1. hint  — shrink-0, never truncates (keymap teaching)
                      #   2. kind  — shrink-0 trailing badge
                      #   3. label — flex-1 min-w-0, keeps space, truncates last
                      #   4. detail — max-w + shrink, loses width first
                      # Below sm (#745): detail/kind/freq collapse; row is label+hint.
                      "group relative flex cursor-pointer items-center gap-2 border-b border-base-200 border-l-2 py-1.5 pl-3 pr-3 last:border-b-0 hover:bg-base-200",
                      "pointer-coarse:min-h-11 pointer-coarse:py-3",
                      if(selected?,
                        do: "border-l-primary bg-primary/15 text-base-content",
                        else: "border-l-transparent"
                      )
                    ]
                  }
                  phx-click="palette:execute"
                  phx-value-id={item.id}
                >
                  <span
                    class={[
                      "min-w-0 flex-1 truncate",
                      if(path_like_label?(item), do: "font-mono", else: "font-sans")
                    ]}
                    title={item.label}
                  >
                    {item.label}
                  </span>
                  <%= if item.detail do %>
                    <span
                      class={[
                        "min-w-0 max-w-[11rem] shrink truncate text-xs text-base-content/55 max-sm:hidden",
                        if(path_like_detail?(item), do: "font-mono", else: "font-sans")
                      ]}
                      title={item.detail}
                    >{item.detail}</span>
                  <% end %>
                  <%= if frequent? do %>
                    <span
                      class="shrink-0 text-density-label uppercase tracking-wide text-base-content/40 max-sm:hidden"
                      title="Promoted by recent use in this workspace"
                    >freq</span>
                  <% end %>
                  <span class="shrink-0 text-density-label uppercase tracking-wide text-base-content/40 max-sm:hidden">{item.kind}</span>
                  <%= if item.hint do %>
                    <kbd class="shrink-0 rounded border border-base-300 bg-base-200 px-1 font-mono text-density-label text-base-content/70">
                      {item.hint}
                    </kbd>
                  <% end %>
                </li>
              <% end %>
            <% end %>
          </ul>
          <div class="flex flex-wrap items-center justify-between gap-2 border-t border-base-300 px-3 py-1.5 text-density-label text-base-content/60">
            <div class="hidden items-center gap-2 sm:flex">
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">↑</kbd>
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">↓</kbd>
                <span class="text-base-content/70">navigate</span>
              </span>
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">↵</kbd>
                <span class="text-base-content/70">run</span>
              </span>
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">Esc</kbd>
                <span class="text-base-content/70">close</span>
              </span>
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">⇥</kbd>
                <span class="text-base-content/70">category</span>
              </span>
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">⌃Space</kbd>
                <span class="text-base-content/70">toggle</span>
              </span>
            </div>
            <span
              id="palette-result-count"
              class={[
                "font-mono tabular-nums",
                @palette_meta.truncated? && "text-warning"
              ]}
              title={
                if @palette_meta.truncated?,
                  do: "Showing the top #{@palette_meta.cap} of #{@palette_meta.total} matches",
                  else: nil
              }
            >
              {result_count_label(@palette_meta)}
            </span>
          </div>
        </div>
      </div>
    <% else %>
      <div id="palette-modal-empty" class="hidden"></div>
    <% end %>
    """
  end

  # Honest cap label. Silent "N item(s)" is gone — when truncated, show "N of M".
  defp result_count_label(%{shown: 0}), do: "0 items"

  defp result_count_label(%{truncated?: true, shown: shown, total: total}),
    do: "#{shown} of #{total}"

  defp result_count_label(%{shown: 1}), do: "1 item"
  defp result_count_label(%{shown: n}), do: "#{n} items"

  defp palette_meta(nil, items) do
    n = length(items)

    %{
      shown: n,
      total: n,
      cap: CaseinWeb.WorkspaceLive.Show.PaletteItems.max_results(),
      truncated?: false,
      frequent_ids: MapSet.new()
    }
  end

  defp palette_meta(meta, items) when is_map(meta) do
    items = items || []

    %{
      shown: Map.get(meta, :shown, length(items)),
      total: Map.get(meta, :total, length(items)),
      cap: Map.get(meta, :cap, CaseinWeb.WorkspaceLive.Show.PaletteItems.max_results()),
      truncated?: Map.get(meta, :truncated?, false),
      frequent_ids: Map.get(meta, :frequent_ids) || MapSet.new()
    }
  end

  # Mono for path-like labels (files, sessions, windows, panes); sans for verbs.
  defp path_like_label?(%{kind: :file}), do: true

  defp path_like_label?(%{id: id}) when is_binary(id) do
    String.starts_with?(id, "session:") or
      String.starts_with?(id, "window:") or
      String.starts_with?(id, "pane:") or
      String.starts_with?(id, "file:") or
      String.starts_with?(id, "file-pane:")
  end

  defp path_like_label?(_), do: false

  defp path_like_detail?(%{kind: :file}), do: true
  defp path_like_detail?(%{id: "preview:surface:" <> _}), do: true
  defp path_like_detail?(_), do: false

  defp palette_selected_id(items, idx) when is_list(items) and items != [] do
    safe_idx = (idx || 0) |> max(0) |> min(length(items) - 1)
    items |> Enum.at(safe_idx) |> Map.get(:id)
  end

  defp palette_selected_id(_, _), do: ""
end
