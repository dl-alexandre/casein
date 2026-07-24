defmodule DevIdeWeb.WorkspaceLive.Show.PaletteEvents do
  # Command-palette and search handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates every "palette:*" and "search:*" event here via prefix
  # delegators.
  # `palette:execute` resolves a palette item to a concrete event and dispatches
  # it back through `Show.handle_event/3` (the same call the inlined version made
  # via `__MODULE__.handle_event/3`).
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import DevIdeWeb.WorkspaceLive.Show.Context

  alias DevIDE.CommandPalette.Usage
  alias DevIDE.Workspaces.FileAccess
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.PaletteItems
  alias DevIdeWeb.WorkspaceLive.Show.TerminalEvents
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  def handle_event("palette:open", _, socket) do
    # The active screen picks the default category tab, so opening the palette
    # over the terminal lands on Tmux verbs, over the editor on Files, etc.
    category = default_palette_category(socket.assigns[:tab])
    open_palette(socket, category)
  end

  # Open the palette scoped to tmux / IDE actions (triggered by a JS hook when
  # the user presses the IDE command keybind inside the terminal).
  def handle_event("palette:ide", _, socket) do
    open_palette(socket, :tmux)
  end

  # Cycle the category tab (Tab / Shift+Tab from PaletteHook, or arrow on the
  # tab strip). Re-runs the current query scoped to the new category.
  def handle_event("palette:category", %{"dir" => dir}, socket) when dir in ["next", "prev"] do
    current = socket.assigns[:palette_category] || :all
    next = cycle_palette_category(current, dir)
    {:noreply, apply_palette_category(socket, next)}
  end

  # Direct selection by clicking a tab in the strip.
  def handle_event("palette:category", %{"category" => name}, socket) do
    case parse_palette_category(name) do
      {:ok, cat} -> {:noreply, apply_palette_category(socket, cat)}
      :error -> {:noreply, socket}
    end
  end

  # Arrow-key navigation pushed from PaletteHook while the modal is open.
  # Wraps at both ends so the list feels infinite. Theme rows live-preview
  # across the terminal LiveView; leaving them restores the committed preset.
  def handle_event("palette:nav", %{"dir" => dir}, socket) do
    n = length(socket.assigns[:palette_items] || [])

    if n == 0 do
      {:noreply, socket}
    else
      cur = socket.assigns[:palette_selected_idx] || 0

      next =
        case dir do
          "up" -> rem(cur - 1 + n, n)
          "down" -> rem(cur + 1, n)
          _ -> cur
        end

      {:noreply,
       socket
       |> assign(:palette_selected_idx, next)
       |> maybe_preview_selected_theme()}
    end
  end

  def handle_event("palette:close", _, socket) do
    {:noreply,
     socket
     |> TerminalEvents.restore_terminal_preset()
     |> assign(:palette_open, false)}
  end

  def handle_event("palette:query", %{"query" => q}, socket) do
    {:noreply,
     socket
     |> assign(:palette_query, q)
     |> assign(:palette_items, PaletteItems.query(socket, q))
     |> assign(:palette_selected_idx, 0)
     |> maybe_preview_selected_theme()}
  end

  def handle_event("palette:templates", _params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      open_palette(socket, :tmux, "template apply")
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  # Form submit (Enter). Prefer the explicitly-selected id from arrow-nav;
  # fall back to top item for safety. Empty → close and restore any theme preview.
  def handle_event("palette:execute", %{"_selected_id" => ""}, socket) do
    {:noreply,
     socket
     |> TerminalEvents.restore_terminal_preset()
     |> assign(:palette_open, false)}
  end

  def handle_event("palette:execute", %{"_selected_id" => id}, socket),
    do: handle_event("palette:execute", %{"id" => id}, socket)

  def handle_event("palette:execute", %{"_top_id" => id}, socket),
    do: handle_event("palette:execute", %{"id" => id}, socket)

  def handle_event("search:run", %{"query" => query}, socket) do
    case context_host_loc(socket) do
      {:ok, loc} ->
        # Run the filesystem grep off the LiveView process so a slow/large
        # search never blocks the channel. Prior results stay visible until
        # handle_async(:run_search, ...) lands.
        trimmed = String.trim(query)

        {:noreply,
         socket
         |> assign(:search_query, query)
         |> start_async(:run_search, fn -> FileAccess.search(loc, trimmed, []) end)}

      _ ->
        {:noreply, assign(socket, :search_state, {:error, :no_root})}
    end
  end

  def handle_event("palette:execute", %{"id" => id}, socket) do
    root =
      case socket.assigns[:host_path] do
        {:ok, r} -> r
        _ -> nil
      end

    case PaletteItems.resolve(socket, root, id) do
      {:ok, %{event: "terminal:set_preset", params: params}} ->
        # Commit the previewed (or newly chosen) theme — do not restore first.
        maybe_record_usage(socket, id)

        socket =
          socket
          |> assign(:palette_open, false)
          |> assign(:palette_theme_preview_id, nil)

        Show.handle_event("terminal:set_preset", params, socket)

      {:ok, %{event: event, params: params}} ->
        maybe_record_usage(socket, id)

        socket =
          socket
          |> TerminalEvents.restore_terminal_preset()
          |> assign(:palette_open, false)

        Show.handle_event(event, params, socket)

      :error ->
        {:noreply,
         socket
         |> TerminalEvents.restore_terminal_preset()
         |> assign(:palette_open, false)}
    end
  end

  ## Internal — palette open / category helpers

  # Only resolved (allowlisted) executions feed frecency. Additionally skip
  # ids whose handler would deny via the tmux-mutation gate — they normally
  # aren't listed (PaletteItems hides them), but a direct execute of a stale
  # id must not let a permanently-failing action inflate its own rank. The
  # dynamic gated ids (rename:*, template:apply:*) already resolve to :error
  # when denied, so they never reach this point.
  defp maybe_record_usage(socket, id) do
    denied_mutation? =
      id in PaletteItems.mutation_gated_ids() and
        not TerminalState.tmux_mutations_allowed?(socket)

    unless denied_mutation? do
      Usage.record(socket.assigns.workspace.id, id)
    end

    :ok
  end

  # Usage (frecency) is loaded once per open, not per keystroke — the map
  # rides in an assign and PaletteItems.query folds it into every ranking
  # until the palette closes.
  defp open_palette(socket, category, query \\ "") do
    usage = Usage.for_workspace(socket.assigns.workspace.id)

    socket =
      socket
      |> assign(:palette_category, category)
      |> assign(:palette_usage, usage)
      |> assign(:palette_query, query)

    items = PaletteItems.query(socket, query)

    {:noreply,
     socket
     |> assign(:palette_open, true)
     |> assign(:palette_items, items)
     |> assign(:palette_selected_idx, 0)
     |> maybe_preview_selected_theme()}
  end

  # Live-preview terminal theme rows as the highlight moves (gsty-style).
  # Non-theme rows restore the committed preset when a preview is active.
  defp maybe_preview_selected_theme(socket) do
    items = socket.assigns[:palette_items] || []
    idx = socket.assigns[:palette_selected_idx] || 0

    case theme_preset_at(items, idx) do
      nil ->
        TerminalEvents.restore_terminal_preset(socket)

      preset ->
        if socket.assigns[:palette_theme_preview_id] == preset do
          socket
        else
          case TerminalEvents.apply_terminal_preset(socket, preset, preview?: true) do
            {:ok, socket} -> socket
            :error -> socket
          end
        end
    end
  end

  defp theme_preset_at(items, idx) do
    case Enum.at(items, idx) do
      %{id: "terminal:theme:" <> preset} -> preset
      _ -> nil
    end
  end

  defp default_palette_category(tab) do
    case tab do
      "terminal" -> :tmux
      "files" -> :files
      "search" -> :files
      "diff" -> :files
      "artifacts" -> :preview
      "run" -> :commands
      _ -> :all
    end
  end

  defp cycle_palette_category(current, dir) do
    cats = Show.palette_categories()
    idx = Enum.find_index(cats, &(&1 == current)) || 0
    n = length(cats)
    next_idx = if dir == "next", do: rem(idx + 1, n), else: rem(idx - 1 + n, n)
    Enum.at(cats, next_idx)
  end

  defp parse_palette_category(name) do
    Show.palette_categories()
    |> Enum.find(&(Atom.to_string(&1) == name))
    |> case do
      nil -> :error
      cat -> {:ok, cat}
    end
  end

  # Re-query under the new category and reset selection to the top.
  defp apply_palette_category(socket, category) do
    socket = assign(socket, :palette_category, category)

    socket
    |> assign(:palette_items, PaletteItems.query(socket, socket.assigns[:palette_query] || ""))
    |> assign(:palette_selected_idx, 0)
    |> maybe_preview_selected_theme()
  end
end
