defmodule DevIdeWeb.WorkspaceLive.Show.PaletteEvents do
  # Command-palette handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates every "palette:*" event here via a prefix delegator.
  # `palette:execute` resolves a palette item to a concrete event and dispatches
  # it back through `Show.handle_event/3` (the same call the inlined version made
  # via `__MODULE__.handle_event/3`).
  @moduledoc false

  import Phoenix.Component

  alias DevIDE.CommandPalette.Recents
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.PaletteItems
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  def handle_event("palette:open", _, socket) do
    # The active screen picks the default category tab, so opening the palette
    # over the terminal lands on Tmux verbs, over the editor on Files, etc.
    category = default_palette_category(socket.assigns[:tab])
    socket = assign(socket, :palette_category, category)
    items = PaletteItems.query(socket, "")

    {:noreply,
     socket
     |> assign(:palette_open, true)
     |> assign(:palette_query, "")
     |> assign(:palette_items, items)
     |> assign(:palette_selected_idx, 0)}
  end

  # Open the palette scoped to tmux / IDE actions (triggered by a JS hook when
  # the user presses the IDE command keybind inside the terminal).
  def handle_event("palette:ide", _, socket) do
    socket = assign(socket, :palette_category, :tmux)
    items = PaletteItems.query(socket, "")

    {:noreply,
     socket
     |> assign(:palette_open, true)
     |> assign(:palette_query, "")
     |> assign(:palette_items, items)
     |> assign(:palette_selected_idx, 0)}
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
  # Wraps at both ends so the list feels infinite.
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

      {:noreply, assign(socket, :palette_selected_idx, next)}
    end
  end

  def handle_event("palette:close", _, socket) do
    {:noreply, assign(socket, :palette_open, false)}
  end

  def handle_event("palette:query", %{"query" => q}, socket) do
    {:noreply,
     socket
     |> assign(:palette_query, q)
     |> assign(:palette_items, PaletteItems.query(socket, q))
     |> assign(:palette_selected_idx, 0)}
  end

  def handle_event("palette:templates", _params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      query = "template apply"

      socket =
        socket
        |> assign(:palette_open, true)
        |> assign(:palette_category, :tmux)
        |> assign(:palette_query, query)

      {:noreply,
       socket
       |> assign(:palette_items, PaletteItems.query(socket, query))
       |> assign(:palette_selected_idx, 0)}
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  # Form submit (Enter). Prefer the explicitly-selected id from arrow-nav;
  # fall back to top item for safety. Empty → just close.
  def handle_event("palette:execute", %{"_selected_id" => ""}, socket),
    do: {:noreply, assign(socket, :palette_open, false)}

  def handle_event("palette:execute", %{"_selected_id" => id}, socket),
    do: handle_event("palette:execute", %{"id" => id}, socket)

  def handle_event("palette:execute", %{"id" => id}, socket) do
    root =
      case socket.assigns[:host_path] do
        {:ok, r} -> r
        _ -> nil
      end

    case PaletteItems.resolve(socket, root, id) do
      {:ok, %{event: event, params: params}} ->
        Recents.record(socket.assigns.workspace.id, id)
        socket = assign(socket, :palette_open, false)
        Show.handle_event(event, params, socket)

      :error ->
        {:noreply, assign(socket, :palette_open, false)}
    end
  end

  ## Internal — palette category helpers (moved verbatim from Show)

  defp default_palette_category(tab) do
    case tab do
      "terminal" -> :tmux
      "agents" -> :agents
      "files" -> :files
      "search" -> :files
      "diff" -> :files
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
  end
end
