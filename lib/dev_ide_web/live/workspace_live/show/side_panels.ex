defmodule DevIdeWeb.WorkspaceLive.Show.SidePanels do
  @moduledoc """
  Side-panel tabs for the workspace cockpit: the Files tree (with project
  card and Elixir symbols outline), Search, Diff, and Run panels.

  Extracted verbatim from `DevIdeWeb.WorkspaceLive.Show`.
  """

  use DevIdeWeb, :html

  import DevIdeWeb.WorkspaceLive.Show.RunPanel

  alias DevIDE.Elixir, as: ElixirNav
  alias DevIDE.Search

  def render_files(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-3 lg:flex-row lg:gap-4">
      <div class="border rounded p-2 overflow-auto bg-zinc-50 space-y-2 max-h-56 lg:max-h-none lg:w-72 lg:flex-none 2xl:w-80">
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
              <button phx-click="tree:refresh" class="rounded border px-1.5">↻</button>
            </div>
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
            <%= if @tree_error do %>
              <p class="text-xs text-red-700">{@tree_error}</p>
            <% end %>
            {render_tree_node(assigns, "")}
            {render_project_card(assigns)}
            {render_symbols_panel(assigns)}
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
              <span id="dirty-indicator" data-dirty="false" class="text-amber-700"></span>
              <span>{@open_file.size}b</span>
              <button
                type="button"
                phx-click={Phoenix.LiveView.JS.dispatch("devide:save", to: "#file-viewer")}
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

  defp render_tree_node(assigns, path) do
    state = Map.get(assigns.tree, path, {:collapsed, []})
    assigns = Map.put(assigns, :node, %{path: path, state: state})

    ~H"""
    <%= case @node.state do %>
      <% {:expanded, entries} -> %>
        <ul class="text-sm">
          <%= for e <- entries do %>
            <li class="pl-3">
              <%= case e.kind do %>
                <% :dir -> %>
                  <div class="flex items-center group">
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
                      class={"text-[10px] px-1 opacity-0 group-hover:opacity-100 " <> if @selected_dir == e.rel_path, do: "opacity-100 text-blue-700", else: ""}
                    >
                      sel
                    </button>
                  </div>
                  <%= if match?({:expanded, _}, Map.get(@tree, e.rel_path)) do %>
                    {render_tree_node(assigns, e.rel_path)}
                  <% end %>
                <% _ -> %>
                  <button
                    phx-click="tree:open"
                    phx-value-path={e.rel_path}
                    class="hover:underline text-left w-full"
                  >
                    <span class="font-mono text-zinc-400">·</span> {e.name}
                  </button>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% _ -> %>
        <p class="text-xs text-zinc-400">(loading…)</p>
    <% end %>
    """
  end

  def render_search(assigns) do
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
    do: "query must be at least #{DevIDE.Search.min_query()} characters."

  defp search_error_text(:too_long),
    do: "query must be at most #{DevIDE.Search.max_query()} characters."

  defp search_error_text(:no_root), do: "workspace path unavailable."
  defp search_error_text(other), do: "search failed: #{inspect(other)}"

  def render_diff(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 min-h-0 lg:flex-row lg:h-[calc(100dvh-14rem)] lg:min-h-[20rem]">
      <aside class="flex flex-col min-h-0 lg:w-72 lg:flex-none 2xl:w-80">
        <h3 class="text-xs font-medium text-zinc-700 mb-2 flex-none">
          Changes <span class="ml-1 text-[10px] font-mono text-zinc-400">{length(@git_status)}</span>
        </h3>
        <%= if @git_status == [] do %>
          <p class="text-sm text-zinc-500">No changes.</p>
        <% else %>
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
              <span class="text-[10px] font-mono text-zinc-400 flex-none ml-2">
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

  def render_run(assigns) do
    ~H"""
    <.run_panel
      host_loc={@host_loc}
      active_run={@active_run}
      run_ledger={@run_ledger}
      selected_run_id={@selected_run_id}
      selected_run_timeline={@selected_run_timeline}
      selected_run_summary={@selected_run_summary}
      selected_run_failure_reason={@selected_run_failure_reason}
      selected_run_can_retry={@selected_run_can_retry}
      selected_run_artifacts={@selected_run_artifacts}
    />
    """
  end

  defp render_project_card(assigns) do
    ~H"""
    <%= if @project_meta do %>
      <details class="border-t pt-1 mt-2 text-[11px]">
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
    <% end %>
    """
  end

  defp render_symbols_panel(assigns) do
    case assigns.open_file do
      %{path: path, content: content} ->
        symbols = ElixirNav.symbols(content, path)
        assigns = Map.put(assigns, :file_symbols, symbols) |> Map.put(:file_path, path)

        ~H"""
        <details class="border-t pt-1 mt-2 text-[11px]" open>
          <summary class="cursor-pointer text-zinc-700">
            Symbols ({length(@file_symbols)})
          </summary>
          <%= cond do %>
            <% String.ends_with?(@file_path, ".heex") -> %>
              <p class="text-zinc-500">HEEx symbols not supported yet.</p>
            <% @file_symbols == [] -> %>
              <p class="text-zinc-500">No symbols.</p>
            <% true -> %>
              <ul class="font-mono space-y-0.5 mt-1">
                <%= for s <- @file_symbols do %>
                  <li>
                    <button
                      phx-click="annotation:open"
                      phx-value-path={@file_path}
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

      _ ->
        ~H""
    end
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
