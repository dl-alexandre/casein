defmodule CaseinWeb.WorkspaceLive.Show.SidePanels do
  @moduledoc """
  Side-panel tabs for the workspace cockpit: the Files tree (with project
  card and Elixir symbols outline), Search, and Diff panels.

  Attr-contracted function components: each panel declares exactly the
  assigns it reads, so the LiveView passes an explicit contract instead of
  the whole assigns bag and change tracking stays per-attr.
  """

  use CaseinWeb, :html

  alias Casein.Links.Markdown
  alias Casein.Search
  alias CaseinWeb.WorkspaceLive.Show.UI

  attr :host_loc, :any, required: true, doc: "{:ok, loc} | error tuple from HostLoc"
  attr :selected_dir, :string, required: true
  attr :new_input, :any, required: true, doc: "{:file | :dir, parent} | nil"
  attr :tree_error, :string, default: nil
  attr :tree, :map, required: true, doc: "rel_path => {:expanded, entries} | {:collapsed, []}"
  attr :project_meta, :any, default: nil
  attr :tooling, :any, default: nil
  attr :open_file, :any, required: true, doc: "%{path:, size:, content: ...} | nil"
  attr :file_symbols, :list, default: [], doc: "precomputed ElixirNav.symbols/2 for open_file"
  attr :rename_input, :string, default: nil
  attr :delete_confirm, :string, default: nil
  attr :save_error, :string, default: nil
  attr :file_error, :string, default: nil
  attr :node_rename, :string, default: nil, doc: "tree-node rename form value (context menu)"
  attr :node_delete, :string, default: nil, doc: "tree-node pending-delete path (context menu)"

  attr :show_hidden_files, :boolean,
    default: true,
    doc: "when false, hide dotfile names in the tree"

  attr :tree_filter, :string,
    default: "",
    doc: "substring/fuzzy filter over visible tree node names"

  attr :side_panels_ready?, :boolean,
    default: true,
    doc: "false while :load_side_panels async has not settled (root tree + initial git)"

  def files_panel(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-3 lg:flex-row lg:gap-4">
      <div
        data-ctx-menu="tree_root"
        class="border rounded p-2 overflow-auto bg-zinc-50 space-y-2 max-h-56 lg:max-h-none lg:w-72 lg:flex-none 2xl:w-80"
      >
        <%= case @host_loc do %>
          <% {:ok, _loc} -> %>
            <div class="flex flex-wrap gap-1 text-xs">
              <span class="px-1 text-zinc-500">in:</span>
              <span class="font-mono text-zinc-700">
                {if @selected_dir == "", do: "/", else: @selected_dir}
              </span>
              <button
                phx-click="tree:new_form"
                phx-value-kind="file"
                class="ml-auto rounded border px-1.5"
              >
                +File
              </button>
              <button phx-click="tree:new_form" phx-value-kind="dir" class="rounded border px-1.5">
                +Dir
              </button>
              <button
                id="tree-toggle-hidden"
                type="button"
                phx-click="tree:toggle_hidden"
                title={if @show_hidden_files, do: "Hide dotfiles", else: "Show dotfiles"}
                aria-pressed={to_string(@show_hidden_files)}
                class={[
                  "rounded border px-1.5",
                  @show_hidden_files && "bg-zinc-200"
                ]}
              >
                {if @show_hidden_files, do: "·hidden", else: "hidden"}
              </button>
              <button phx-click="tree:refresh" class="rounded border px-1.5">↻</button>
            </div>
            <form phx-change="tree:filter" phx-submit="tree:filter" class="flex gap-1 text-xs">
              <input
                id="tree-filter-input"
                type="search"
                name="q"
                value={@tree_filter}
                phx-debounce="200"
                placeholder="filter names…"
                autocomplete="off"
                class="flex-1 border rounded px-1.5 py-0.5 font-mono"
              />
            </form>
            <%= if @new_input do %>
              <.form for={%{}} phx-submit="tree:create" class="flex gap-1 text-xs">
                <input
                  id="tree-new-name-input"
                  name="name"
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                  placeholder={if elem(@new_input, 0) == :file, do: "filename", else: "dir name"}
                  class="flex-1 border rounded px-1 py-0.5 font-mono"
                />
                <button class="rounded bg-zinc-900 text-white px-2 py-0.5">create</button>
                <button type="button" phx-click="tree:cancel_new" class="rounded border px-2 py-0.5">
                  x
                </button>
              </.form>
            <% end %>
            <%= if @node_rename do %>
              <.form for={%{}} phx-submit="tree:rename_node" class="flex gap-1 text-xs">
                <input
                  id="tree-rename-node-input"
                  name="to"
                  value={@node_rename}
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                  class="flex-1 border rounded px-1 py-0.5 font-mono"
                />
                <button class="rounded bg-zinc-900 text-white px-2 py-0.5">rename</button>
                <button
                  type="button"
                  phx-click="tree:rename_node_cancel"
                  class="rounded border px-2 py-0.5"
                >
                  x
                </button>
              </.form>
            <% end %>
            <%= if @node_delete do %>
              <div class="flex items-center justify-between gap-1 rounded border border-red-200 bg-red-50 px-1.5 py-1 text-xs">
                <span class="min-w-0 truncate">
                  Delete <span class="font-mono">{@node_delete}</span> and its contents?
                </span>
                <span class="flex gap-1">
                  <button
                    phx-click="tree:delete_node_confirm"
                    class="rounded bg-red-700 text-white px-2 py-0.5"
                  >
                    confirm
                  </button>
                  <button phx-click="tree:delete_node_cancel" class="rounded border px-2 py-0.5">
                    cancel
                  </button>
                </span>
              </div>
            <% end %>
            <%= if @tree_error do %>
              <p class="text-xs text-red-700">{@tree_error}</p>
            <% end %>
            <.tree_node
              tree={@tree}
              selected_dir={@selected_dir}
              tree_filter={@tree_filter}
              path=""
              side_panels_ready?={@side_panels_ready?}
            />
            <.project_card project_meta={@project_meta} tooling={@tooling} />
            <.symbols_panel open_file={@open_file} file_symbols={@file_symbols} />
          <% _ -> %>
            <p class="text-xs text-red-700">No host path; cannot list files.</p>
        <% end %>
      </div>
      <div class="border rounded flex flex-col flex-1 min-w-0 min-h-0">
        <%= if @open_file do %>
          <div class="px-3 py-1.5 border-b bg-zinc-50 text-xs font-mono flex flex-wrap justify-between items-center gap-2">
            <%= if @rename_input do %>
              <.form for={%{}} phx-submit="file:rename_submit" class="flex gap-1 flex-1">
                <input name="new_path" value={@rename_input} class="flex-1 border rounded px-1" />
                <button class="rounded bg-zinc-900 text-white px-2">rename</button>
                <button type="button" phx-click="file:rename_cancel" class="rounded border px-2">
                  x
                </button>
              </.form>
            <% else %>
              <span class="truncate">{@open_file.path}</span>
            <% end %>
            <span class="flex items-center gap-2 text-zinc-500">
              <%= if Markdown.markdown_path?(@open_file.path) do %>
                <span class="inline-flex overflow-hidden rounded border border-zinc-300 bg-white text-density-body">
                  <button
                    type="button"
                    phx-click={
                      Phoenix.LiveView.JS.dispatch("casein:file-mode",
                        to: "#file-viewer",
                        detail: %{mode: "source"}
                      )
                    }
                    class={[
                      "px-2 py-0.5 transition",
                      @file_render_mode != "rendered" && "bg-zinc-900 text-white",
                      @file_render_mode == "rendered" && "hover:bg-zinc-100"
                    ]}
                  >
                    Source
                  </button>
                  <button
                    type="button"
                    phx-click={
                      Phoenix.LiveView.JS.dispatch("casein:file-mode",
                        to: "#file-viewer",
                        detail: %{mode: "rendered"}
                      )
                    }
                    class={[
                      "border-l border-zinc-300 px-2 py-0.5 transition",
                      @file_render_mode == "rendered" && "bg-zinc-900 text-white",
                      @file_render_mode != "rendered" && "hover:bg-zinc-100"
                    ]}
                  >
                    Rendered
                  </button>
                </span>
              <% end %>
              <span id="dirty-indicator" data-dirty="false" class="text-amber-700"></span>
              <span id="stale-indicator" data-stale="false" class="text-orange-700"></span>
              <span>{@open_file.size}b</span>
              <button
                type="button"
                phx-click={Phoenix.LiveView.JS.dispatch("casein:save", to: "#file-viewer")}
                class="rounded bg-zinc-900 text-white px-2 py-0.5"
              >
                Save
              </button>
              <button type="button" phx-click="file:refresh" class="rounded border px-2 py-0.5">
                Refresh
              </button>
              <button type="button" phx-click="file:rename_form" class="rounded border px-2 py-0.5">
                Rename
              </button>
              <button
                type="button"
                phx-click="file:delete_request"
                class="rounded border px-2 py-0.5 text-red-700"
              >
                Delete
              </button>
            </span>
          </div>
          <%= if @delete_confirm do %>
            <div class="px-3 py-1 border-b bg-red-50 text-xs flex justify-between items-center">
              <span>Delete <span class="font-mono">{@delete_confirm}</span>?</span>
              <span class="flex gap-1">
                <button
                  phx-click="file:delete_confirm"
                  class="rounded bg-red-700 text-white px-2 py-0.5"
                >
                  confirm
                </button>
                <button phx-click="file:delete_cancel" class="rounded border px-2 py-0.5">
                  cancel
                </button>
              </span>
            </div>
          <% end %>
          <%= if @save_error do %>
            <div class="px-3 py-1 border-b bg-red-50 text-xs text-red-800">{@save_error}</div>
          <% end %>
        <% else %>
          <div class="px-3 py-1.5 border-b bg-zinc-50 text-xs text-zinc-500">
            {@file_error || "Select a file to view."}
          </div>
        <% end %>
        <div
          id="file-viewer"
          phx-hook="FileViewerHook"
          phx-update="ignore"
          class="flex-1 overflow-auto"
        >
        </div>
      </div>
    </section>
    """
  end

  attr :tree, :map, required: true, doc: "rel_path => {:expanded, entries} | {:collapsed, []}"
  attr :selected_dir, :string, required: true
  attr :tree_filter, :string, default: ""
  attr :path, :string, required: true, doc: "tree node path; root is \"\""

  attr :side_panels_ready?, :boolean,
    default: true,
    doc: "false while initial root hydration is still in flight"

  # Recursive file-tree node. Attr-contracted so a selected_dir-only change
  # does not force the symbols panel (or project card) to re-render.
  defp tree_node(assigns) do
    state = Map.get(assigns.tree, assigns.path, {:collapsed, []})

    state =
      case state do
        {:expanded, entries} ->
          {:expanded, filter_tree_entries(entries, assigns.tree, assigns.tree_filter)}

        other ->
          other
      end

    # Root stays collapsed until :load_side_panels expands it. Nested paths
    # that are still collapsed are user-closed dirs, not hydration waits —
    # never flash a spinner on those.
    waiting_root? =
      assigns.path == "" and not match?({:expanded, _}, state) and
        assigns.side_panels_ready? != true

    assigns =
      assigns
      |> assign(:node, %{path: assigns.path, state: state})
      |> assign(:waiting_root?, waiting_root?)

    ~H"""
    <%= case @node.state do %>
      <% {:expanded, entries} -> %>
        <ul class="text-sm">
          <%= if entries == [] and String.trim(@tree_filter || "") != "" do %>
            <li class="pl-3 text-xs text-zinc-400">(no matches)</li>
          <% end %>
          <%= for e <- entries do %>
            <li class="pl-3">
              <%= case e.kind do %>
                <% :dir -> %>
                  <div
                    data-ctx-menu="tree_node"
                    data-ctx-kind="dir"
                    data-ctx-path={e.rel_path}
                    class="flex items-center group"
                  >
                    <button
                      phx-click="tree:toggle"
                      phx-value-path={e.rel_path}
                      class="hover:underline text-left flex-1"
                    >
                      <span class="font-mono text-amber-700">▸</span> {e.name}/
                    </button>
                    <button
                      phx-click="tree:select_dir"
                      phx-value-path={e.rel_path}
                      title="select for new file/dir"
                      class={"text-density-label px-1 opacity-0 group-hover:opacity-100 " <> if @selected_dir == e.rel_path, do: "opacity-100 text-blue-700", else: ""}
                    >
                      sel
                    </button>
                  </div>
                  <%= if match?({:expanded, _}, Map.get(@tree, e.rel_path)) do %>
                    <.tree_node
                      tree={@tree}
                      selected_dir={@selected_dir}
                      tree_filter={@tree_filter}
                      path={e.rel_path}
                      side_panels_ready?={@side_panels_ready?}
                    />
                  <% end %>
                <% _ -> %>
                  <button
                    phx-click="tree:open"
                    phx-value-path={e.rel_path}
                    data-ctx-menu="tree_node"
                    data-ctx-kind="file"
                    data-ctx-path={e.rel_path}
                    class="hover:underline text-left w-full"
                  >
                    <span class="font-mono text-zinc-400">·</span> {e.name}
                  </button>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% _ -> %>
        <%= if @waiting_root? do %>
          <UI.async_wait id="files-tree-loading" class="text-xs text-zinc-400">
            Reading the file tree…
          </UI.async_wait>
        <% end %>
    <% end %>
    """
  end

  # Filter only affects presentation of already-loaded nodes. Directories stay
  # visible when an expanded descendant matches so paths remain navigable.
  defp filter_tree_entries(entries, _tree, filter)
       when filter in [nil, ""],
       do: entries

  defp filter_tree_entries(entries, tree, filter) when is_list(entries) do
    q =
      filter
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if q == "" do
      entries
    else
      Enum.filter(entries, fn e ->
        name_match?(e.name, q) or
          (e.kind == :dir and descendant_name_match?(tree, e.rel_path, q))
      end)
    end
  end

  defp descendant_name_match?(tree, path, q) do
    case Map.get(tree, path) do
      {:expanded, children} when is_list(children) ->
        Enum.any?(children, fn c ->
          name_match?(c.name, q) or
            (c.kind == :dir and descendant_name_match?(tree, c.rel_path, q))
        end)

      _ ->
        false
    end
  end

  defp name_match?(name, q) when is_binary(name) and is_binary(q) do
    n = String.downcase(name)
    String.contains?(n, q) or fuzzy_name_match?(n, q)
  end

  defp name_match?(_, _), do: false

  # Lightweight fuzzy: query characters appear in order in the name.
  defp fuzzy_name_match?(name, q) do
    q
    |> String.graphemes()
    |> Enum.reduce_while(String.graphemes(name), fn ch, rest ->
      case Enum.split_while(rest, &(&1 != ch)) do
        {_prefix, [^ch | next]} -> {:cont, next}
        _ -> {:halt, :no}
      end
    end) != :no
  end

  attr :search_query, :string, required: true
  attr :search_results, :list, required: true

  attr :search_state, :any,
    required: true,
    doc: ":idle | :running | :empty | :ok | {:error, reason}"

  def search_panel(assigns) do
    grouped =
      assigns.search_results
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(fn {p, _} -> p end)

    assigns = Map.put(assigns, :grouped_results, grouped)

    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-3">
      <.form for={%{}} phx-submit="search:run" class="flex flex-wrap gap-2 items-center flex-none">
        <input
          name="query"
          value={@search_query}
          placeholder="search workspace…"
          autocomplete="off"
          class="flex-1 min-w-[12rem] border rounded px-2 py-1 text-sm font-mono"
        />
        <button class="rounded bg-zinc-900 text-white px-3 py-1 text-sm">Search</button>
        <span class="text-xs text-zinc-500">
          rg: {if Search.available?(), do: "available", else: "missing"}
        </span>
      </.form>
      <div class="flex-1 min-h-0 overflow-auto pr-1">
        {render_search_state(assigns)}
      </div>
    </section>
    """
  end

  defp render_search_state(assigns) do
    case assigns.search_state do
      :idle ->
        ~H"""
        <p class="text-xs text-zinc-500">
          Type {Search.min_query()}+ chars and press Enter. Searches the workspace via <code>rg</code>; results are PathSafety-checked.
        </p>
        """

      :running ->
        ~H"""
        <UI.async_wait id="search-running" class="text-xs text-zinc-500">
          Searching the workspace…
        </UI.async_wait>
        """

      :empty ->
        ~H"""
        <p class="text-xs text-zinc-500">No matches.</p>
        """

      :ok ->
        ~H"""
        <p class="text-xs text-zinc-500">
          {length(@search_results)} match(es) in {length(@grouped_results)} file(s)
          (cap {Search.result_cap()}).
        </p>
        <ul class="text-xs space-y-2">
          <%= for {path, items} <- @grouped_results do %>
            <li>
              <div class="font-mono text-zinc-700">{path} ({length(items)})</div>
              <ul class="ml-3 space-y-0.5">
                <%= for r <- items do %>
                  <li>
                    <button
                      phx-click="annotation:open"
                      phx-value-path={r.path}
                      phx-value-line={r.line}
                      class="font-mono hover:underline text-left"
                    >
                      :{r.line}{if r.column, do: ":" <> Integer.to_string(r.column)}
                    </button>
                    <span class="text-zinc-600 font-mono">— {r.preview}</span>
                  </li>
                <% end %>
              </ul>
            </li>
          <% end %>
        </ul>
        """

      {:error, reason} ->
        assigns = Map.put(assigns, :reason, reason)

        ~H"""
        <p class="text-xs text-red-700">{search_error_text(@reason)}</p>
        """
    end
  end

  defp search_error_text(:rg_missing),
    do: "ripgrep (rg) is not installed on the host; install it to enable search."

  defp search_error_text(:timeout), do: "search timed out; try a more specific query."

  defp search_error_text(:too_short),
    do: "query must be at least #{Casein.Search.min_query()} characters."

  defp search_error_text(:too_long),
    do: "query must be at most #{Casein.Search.max_query()} characters."

  defp search_error_text(:no_root), do: "workspace path unavailable."
  defp search_error_text(other), do: "search failed: #{inspect(other)}"

  attr :git_status, :list, required: true
  attr :open_file, :any, required: true
  attr :file_diff, :any, required: true, doc: "unified diff string | nil"

  attr :git_status_ready?, :boolean,
    default: true,
    doc: "false while git status async has not settled"

  def diff_panel(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 min-h-0 lg:flex-row lg:h-[calc(100dvh-14rem)] lg:min-h-[20rem]">
      <aside class="flex flex-col min-h-0 lg:w-72 lg:flex-none 2xl:w-80">
        <h3 class="text-xs font-medium text-zinc-700 mb-2 flex-none">
          Changes
          <span class="ml-1 text-density-label font-mono text-zinc-400">{length(@git_status)}</span>
        </h3>
        <%= cond do %>
          <% not @git_status_ready? and @git_status == [] -> %>
            <UI.async_wait id="diff-git-loading" class="text-sm text-zinc-500">
              Querying git…
            </UI.async_wait>
          <% @git_status == [] -> %>
            <p class="text-sm text-zinc-500">No changes.</p>
          <% true -> %>
            <ul class="text-xs space-y-0.5 overflow-auto pr-1 max-h-48 lg:max-h-none lg:flex-1 lg:min-h-0">
              <%= for e <- @git_status do %>
                <li>
                  <button
                    type="button"
                    phx-click="annotation:open"
                    phx-value-path={e.path}
                    class={[
                      "w-full rounded px-2 py-1 text-left font-mono transition hover:bg-zinc-100 flex items-center gap-2",
                      @open_file && @open_file.path == e.path && "bg-zinc-100 border border-zinc-300"
                    ]}
                  >
                    <span class={git_status_badge_class(e.x, e.y)}>{e.x}{e.y}</span>
                    <span class="truncate">{e.path}</span>
                  </button>
                </li>
              <% end %>
            </ul>
        <% end %>
      </aside>

      <div class="flex flex-col min-w-0 min-h-0 flex-1">
        <%= cond do %>
          <% is_nil(@open_file) -> %>
            <p class="text-sm text-zinc-500">Select a file to view its diff.</p>
          <% is_nil(@file_diff) -> %>
            <p class="text-sm text-zinc-500">
              No diff for <span class="font-mono">{@open_file.path}</span> (no working-tree changes).
            </p>
          <% true -> %>
            <div class="flex items-center justify-between mb-2 flex-none">
              <span class="font-mono text-xs text-zinc-700 truncate">{@open_file.path}</span>
              <span class="text-density-label font-mono text-zinc-400 flex-none ml-2">
                {diff_stat_label(@file_diff)}
              </span>
            </div>
            <pre class="bg-zinc-950 text-zinc-100 text-xs rounded overflow-auto leading-relaxed flex-1 min-h-[12rem] max-h-[60dvh] lg:max-h-none"><%= for {line, idx} <- diff_lines(@file_diff) do %><code class={diff_line_class(line)} id={"diff-line-#{idx}"}><%= line %><br/></code><% end %></pre>
        <% end %>
      </div>
    </section>
    """
  end

  defp diff_lines(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.with_index()
  end

  defp diff_lines(_), do: []

  defp diff_line_class(line) do
    base = "block px-3 font-mono whitespace-pre"

    cond do
      String.starts_with?(line, "+++") or String.starts_with?(line, "---") ->
        base <> " text-zinc-400"

      String.starts_with?(line, "@@") ->
        base <> " text-cyan-300 bg-zinc-900"

      String.starts_with?(line, "+") ->
        base <> " text-emerald-300 bg-emerald-950/40"

      String.starts_with?(line, "-") ->
        base <> " text-rose-300 bg-rose-950/40"

      String.starts_with?(line, "diff ") or String.starts_with?(line, "index ") ->
        base <> " text-zinc-500"

      true ->
        base <> " text-zinc-300"
    end
  end

  defp diff_stat_label(diff) when is_binary(diff) do
    lines = String.split(diff, "\n")

    adds =
      Enum.count(lines, fn l ->
        String.starts_with?(l, "+") and not String.starts_with?(l, "+++")
      end)

    dels =
      Enum.count(lines, fn l ->
        String.starts_with?(l, "-") and not String.starts_with?(l, "---")
      end)

    "+#{adds} −#{dels}"
  end

  defp diff_stat_label(_), do: ""

  defp git_status_badge_class(x, y) do
    color =
      cond do
        x == "?" or y == "?" -> "text-violet-700"
        x == "A" or y == "A" -> "text-emerald-700"
        x == "D" or y == "D" -> "text-rose-700"
        x == "M" or y == "M" -> "text-amber-700"
        true -> "text-zinc-600"
      end

    "inline-block w-6 text-center #{color}"
  end

  attr :artifact_projects, :list, default: []
  attr :artifact_projects_error, :string, default: nil
  attr :artifact_selected_id, :string, default: nil

  def artifact_gallery_panel(assigns) do
    assigns =
      assign(
        assigns,
        :selected_artifact_project,
        selected_artifact_project(assigns.artifact_projects, assigns.artifact_selected_id)
      )

    ~H"""
    <section
      id="artifact-gallery-panel"
      class="flex h-full min-h-0 flex-col border border-base-300 bg-base-100"
    >
      <div class="flex shrink-0 items-center justify-between gap-3 border-b border-base-300 bg-base-200/45 px-3 py-2">
        <div class="min-w-0">
          <h2 class="truncate text-sm font-semibold text-base-content">Artifacts</h2>
          <p class="text-xs text-base-content/55">{artifact_count_label(@artifact_projects)}</p>
        </div>
        <button
          id="artifact-refresh-button"
          type="button"
          phx-click="artifact:refresh"
          class="inline-flex size-8 shrink-0 items-center justify-center rounded border border-base-300 bg-base-100 text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content"
          title="Refresh artifacts"
          aria-label="Refresh artifacts"
        >
          <.icon name="hero-arrow-path" class="size-4" />
        </button>
      </div>

      <div
        :if={@artifact_projects_error}
        id="artifact-gallery-error"
        class="border-b border-error/20 bg-error/10 px-3 py-2 text-xs text-error"
      >
        {@artifact_projects_error}
      </div>

      <div class="min-h-0 flex-1 overflow-auto p-3">
        <div
          :if={@artifact_projects == []}
          id="artifact-gallery-empty"
          class="flex h-full min-h-44 items-center justify-center border border-dashed border-base-300 bg-base-200/30 p-6 text-center text-sm text-base-content/55"
        >
          No artifacts yet.
        </div>

        <div
          :if={@artifact_projects != []}
          class="grid h-full min-h-[28rem] gap-3 xl:grid-cols-[minmax(19rem,0.9fr)_minmax(24rem,1.1fr)]"
        >
          <div class="min-h-0 overflow-auto">
            <div class="grid gap-3 2xl:grid-cols-2">
              <article
                :for={project <- @artifact_projects}
                id={"artifact-card-" <> artifact_id(project)}
                class={artifact_card_class(project, @artifact_selected_id)}
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <h3
                      class="truncate text-sm font-semibold text-base-content"
                      title={artifact_name(project)}
                    >
                      {artifact_name(project)}
                    </h3>
                    <div class="mt-1 flex flex-wrap items-center gap-1.5 text-density-body">
                      <span class={[
                        "inline-flex items-center rounded border px-1.5 py-0.5 font-medium",
                        artifact_status_class(artifact_status(project))
                      ]}>
                        {artifact_status(project)}
                      </span>
                      <span class="rounded border border-base-300 bg-base-200 px-1.5 py-0.5 font-mono text-base-content/60">
                        {artifact_kind(project)}
                      </span>
                      <span
                        :if={artifact_branch(project)}
                        class="max-w-36 truncate rounded border border-base-300 bg-base-100 px-1.5 py-0.5 font-mono text-base-content/55"
                        title={artifact_branch(project)}
                      >
                        {artifact_branch(project)}
                      </span>
                    </div>
                  </div>
                  <div class="flex shrink-0 items-center gap-1">
                    <button
                      type="button"
                      phx-click="artifact:inspect"
                      phx-value-artifact-id={artifact_id(project)}
                      class="inline-flex size-8 items-center justify-center rounded border border-base-300 bg-base-100 text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content"
                      title="Inspect artifact"
                      aria-label={"Inspect " <> artifact_name(project)}
                    >
                      <.icon name="hero-eye" class="size-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="artifact:serve"
                      phx-value-artifact-id={artifact_id(project)}
                      class="inline-flex size-8 items-center justify-center rounded border border-base-300 bg-base-100 text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content"
                      title="Start artifact preview server"
                      aria-label={"Start preview server for " <> artifact_name(project)}
                    >
                      <.icon name="hero-play" class="size-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="artifact:open"
                      phx-value-artifact-id={artifact_id(project)}
                      disabled={!artifact_preview_available?(project)}
                      class="inline-flex size-8 items-center justify-center rounded border border-base-300 bg-primary text-primary-content transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:border-base-300 disabled:bg-base-200 disabled:text-base-content/35"
                      title="Open artifact preview"
                      aria-label={"Open preview for " <> artifact_name(project)}
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                    </button>
                  </div>
                </div>

                <dl class="mt-3 grid gap-2 text-xs">
                  <div class="min-w-0">
                    <dt class="text-density-label font-semibold uppercase text-base-content/40">
                      Preview
                    </dt>
                    <dd
                      class="mt-0.5 truncate font-mono text-base-content/70"
                      title={artifact_preview_url(project) || "Not started"}
                    >
                      {artifact_preview_url(project) || "Not started"}
                    </dd>
                  </div>
                  <div class="min-w-0">
                    <dt class="text-density-label font-semibold uppercase text-base-content/40">
                      Worktree
                    </dt>
                    <dd
                      class="mt-0.5 truncate font-mono text-base-content/70"
                      title={artifact_worktree_path(project)}
                    >
                      {artifact_worktree_path(project)}
                    </dd>
                  </div>
                  <div :if={artifact_prompt_preview(project)} class="min-w-0">
                    <dt class="text-density-label font-semibold uppercase text-base-content/40">
                      Latest Prompt
                    </dt>
                    <dd class="mt-0.5 line-clamp-2 text-base-content/70">
                      {artifact_prompt_preview(project)}
                    </dd>
                  </div>
                </dl>

                <div class="mt-auto pt-3 text-density-body text-base-content/45">
                  Updated {artifact_updated_label(project)}
                </div>
              </article>
            </div>
          </div>
          <.artifact_detail_panel
            :if={@selected_artifact_project}
            project={@selected_artifact_project}
          />
        </div>
      </div>
    </section>
    """
  end

  defp artifact_count_label(projects) do
    count = length(projects || [])
    "#{count} artifact" <> if(count == 1, do: "", else: "s")
  end

  attr :project, :any, required: true

  defp artifact_detail_panel(assigns) do
    ~H"""
    <aside
      id={"artifact-detail-" <> artifact_id(@project)}
      class="flex min-h-0 flex-col border border-base-300 bg-base-100"
    >
      <div class="flex shrink-0 items-start justify-between gap-3 border-b border-base-300 bg-base-200/40 px-3 py-2">
        <div class="min-w-0">
          <h3 class="truncate text-sm font-semibold text-base-content" title={artifact_name(@project)}>
            {artifact_name(@project)}
          </h3>
          <p class="mt-0.5 truncate font-mono text-xs text-base-content/55">
            {artifact_id(@project)}
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <button
            type="button"
            phx-click="artifact:serve"
            phx-value-artifact-id={artifact_id(@project)}
            class="inline-flex size-8 items-center justify-center rounded border border-base-300 bg-base-100 text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content"
            title="Start artifact preview server"
            aria-label={"Start preview server for " <> artifact_name(@project)}
          >
            <.icon name="hero-play" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="artifact:open"
            phx-value-artifact-id={artifact_id(@project)}
            disabled={!artifact_preview_available?(@project)}
            class="inline-flex size-8 items-center justify-center rounded border border-base-300 bg-primary text-primary-content transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:border-base-300 disabled:bg-base-200 disabled:text-base-content/35"
            title="Open artifact preview"
            aria-label={"Open preview for " <> artifact_name(@project)}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </button>
        </div>
      </div>

      <div class="min-h-0 flex-1 overflow-auto p-3">
        <iframe
          :if={artifact_embedded_preview_url(@project)}
          id="artifact-embedded-preview"
          src={artifact_embedded_preview_url(@project)}
          class="h-full min-h-80 w-full border border-base-300 bg-white"
          sandbox="allow-forms allow-modals allow-popups allow-scripts"
          referrerpolicy="no-referrer"
          title={"Embedded preview for " <> artifact_name(@project)}
        ></iframe>

        <div
          :if={!artifact_embedded_preview_url(@project)}
          id="artifact-embedded-preview-unavailable"
          class="flex min-h-80 flex-col justify-center border border-dashed border-base-300 bg-base-200/35 p-5"
        >
          <div class="mx-auto flex size-10 items-center justify-center rounded border border-base-300 bg-base-100 text-base-content/55">
            <.icon name="hero-window" class="size-5" />
          </div>
          <p class="mx-auto mt-3 max-w-md text-center text-sm text-base-content/65">
            No embedded preview
          </p>
          <p class="mx-auto mt-1 max-w-md truncate text-center font-mono text-xs text-base-content/45">
            {artifact_preview_url(@project) || "Preview server not started"}
          </p>
        </div>

        <dl class="mt-3 grid gap-2 text-xs md:grid-cols-2">
          <div class="min-w-0">
            <dt class="text-density-label font-semibold uppercase text-base-content/40">Status</dt>
            <dd class="mt-0.5 text-base-content/70">{artifact_status(@project)}</dd>
          </div>
          <div class="min-w-0">
            <dt class="text-density-label font-semibold uppercase text-base-content/40">Kind</dt>
            <dd class="mt-0.5 text-base-content/70">{artifact_kind(@project)}</dd>
          </div>
          <div class="min-w-0 md:col-span-2">
            <dt class="text-density-label font-semibold uppercase text-base-content/40">Worktree</dt>
            <dd
              class="mt-0.5 truncate font-mono text-base-content/70"
              title={artifact_worktree_path(@project)}
            >
              {artifact_worktree_path(@project)}
            </dd>
          </div>
          <div :if={artifact_prompt_preview(@project)} class="min-w-0 md:col-span-2">
            <dt class="text-density-label font-semibold uppercase text-base-content/40">
              Latest Prompt
            </dt>
            <dd class="mt-0.5 text-base-content/70">{artifact_prompt_preview(@project)}</dd>
          </div>
        </dl>
      </div>
    </aside>
    """
  end

  defp artifact_id(project), do: artifact_value(project, :id) || ""
  defp artifact_name(project), do: artifact_value(project, :name) || artifact_id(project)
  defp artifact_kind(project), do: artifact_value(project, :kind) || "static"
  defp artifact_status(project), do: artifact_value(project, :status) || "draft"
  defp artifact_branch(project), do: blank_to_nil(artifact_value(project, :branch))
  defp artifact_preview_url(project), do: blank_to_nil(artifact_value(project, :preview_url))
  defp artifact_worktree_path(project), do: artifact_value(project, :worktree_path) || ""

  defp artifact_preview_available?(project), do: is_binary(artifact_preview_url(project))

  defp artifact_embedded_preview_url(project) do
    case artifact_preview_url(project) do
      "/" <> _ = url -> if(String.starts_with?(url, "//"), do: nil, else: url)
      _ -> nil
    end
  end

  defp artifact_card_class(project, selected_id) do
    [
      "flex min-h-52 min-w-0 flex-col border bg-base-100 p-3 shadow-sm transition hover:border-primary/30 hover:shadow",
      artifact_id(project) == selected_id && "border-primary/50 ring-1 ring-primary/25",
      artifact_id(project) != selected_id && "border-base-300"
    ]
  end

  defp selected_artifact_project(projects, selected_id) when is_binary(selected_id) do
    Enum.find(projects || [], &(artifact_id(&1) == selected_id))
  end

  defp selected_artifact_project(_projects, _selected_id), do: nil

  defp artifact_prompt_preview(project) do
    project
    |> artifact_value(:prompt_history)
    |> case do
      prompts when is_list(prompts) -> prompts |> List.last() |> blank_to_nil()
      _ -> nil
    end
  end

  defp artifact_updated_label(project) do
    case artifact_value(project, :updated_at) do
      %DateTime{} = updated_at -> Calendar.strftime(updated_at, "%Y-%m-%d %H:%M UTC")
      value when is_binary(value) and value != "" -> value
      _ -> "unknown"
    end
  end

  defp artifact_status_class(status) do
    case status do
      "live" -> "border-emerald-500/30 bg-emerald-500/10 text-emerald-700"
      "running" -> "border-emerald-500/30 bg-emerald-500/10 text-emerald-700"
      "provisioned" -> "border-sky-500/30 bg-sky-500/10 text-sky-700"
      "draft" -> "border-amber-500/30 bg-amber-500/10 text-amber-700"
      "error" -> "border-error/30 bg-error/10 text-error"
      _ -> "border-base-300 bg-base-200 text-base-content/65"
    end
  end

  defp artifact_value(project, key) when is_map(project) and is_atom(key) do
    Map.get(project, key) || Map.get(project, Atom.to_string(key))
  end

  defp artifact_value(_project, _key), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil

  attr :project_meta, :any, default: nil
  attr :tooling, :any, default: nil

  defp project_card(assigns) do
    ~H"""
    <details :if={@project_meta} class="border-t pt-1 mt-2 text-density-body">
      <summary class="cursor-pointer text-zinc-700">Project</summary>
      <ul class="mt-1 space-y-0.5">
        <li>Mix: {yes_no(@project_meta.mix?)}</li>
        <li>Umbrella: {yes_no(@project_meta.umbrella?)}</li>
        <li>Phoenix: {yes_no(@project_meta.phoenix?)}</li>
        <li>LiveView: {yes_no(@project_meta.live_view?)}</li>
        <li>Ecto: {yes_no(@project_meta.ecto?)}</li>
        <li>Formatter: {yes_no(@project_meta.formatter?)}</li>
        <%= if @tooling do %>
          <li>
            Lexical: {detected_or_missing(@tooling.lexical? or @tooling.mix_lock_lexical?)}
          </li>
          <li>
            ElixirLS: {detected_or_missing(@tooling.elixir_ls? or @tooling.mix_lock_elixir_ls?)}
          </li>
        <% end %>
      </ul>
    </details>
    """
  end

  attr :open_file, :any, required: true, doc: "%{path:, size:, content: ...} | nil"
  attr :file_symbols, :list, default: [], doc: "precomputed ElixirNav.symbols/2 for open_file"

  # Reads memoized :file_symbols from the LiveView — never re-parses content.
  defp symbols_panel(assigns) do
    ~H"""
    <details :if={@open_file} class="border-t pt-1 mt-2 text-density-body" open>
      <summary class="cursor-pointer text-zinc-700">
        Symbols ({length(@file_symbols)})
      </summary>
      <%= cond do %>
        <% String.ends_with?(@open_file.path, ".heex") -> %>
          <p class="text-zinc-500">HEEx symbols not supported yet.</p>
        <% @file_symbols == [] -> %>
          <p class="text-zinc-500">No symbols.</p>
        <% true -> %>
          <ul class="font-mono space-y-0.5 mt-1">
            <%= for s <- @file_symbols do %>
              <li>
                <button
                  phx-click="annotation:open"
                  phx-value-path={@open_file.path}
                  phx-value-line={s.line}
                  class={"hover:underline text-left " <> symbol_color(s)}
                >
                  <span class="text-zinc-400">{symbol_glyph(s.kind)}</span>
                  {s.name}
                  <%= if s.visibility == :private do %>
                    <span class="text-zinc-400">priv</span>
                  <% end %>
                  <span class="text-zinc-400">:{s.line}</span>
                </button>
              </li>
            <% end %>
          </ul>
      <% end %>
    </details>
    """
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"
  defp detected_or_missing(true), do: "detected"
  defp detected_or_missing(_), do: "missing"

  defp symbol_glyph(:module), do: "M"
  defp symbol_glyph(:function), do: "f"
  defp symbol_glyph(:macro), do: "ƒ"
  defp symbol_glyph(:guard), do: "g"
  defp symbol_glyph(:delegate), do: "→"
  defp symbol_glyph(:test), do: "t"
  defp symbol_glyph(:describe), do: "d"
  defp symbol_glyph(_), do: "?"

  defp symbol_color(%{kind: :module}), do: "text-blue-700"
  defp symbol_color(%{visibility: :private}), do: "text-zinc-500"
  defp symbol_color(%{kind: :test}), do: "text-purple-700"
  defp symbol_color(%{kind: :describe}), do: "text-purple-700"
  defp symbol_color(_), do: "text-zinc-800"
end
