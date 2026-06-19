defmodule DevIdeWeb.WorkspaceLive.Show.AgentsPanel do
  @moduledoc """
  Agents tab for the workspace cockpit: agent capability cards, proposal
  list/detail (diff, analysis, isolation), and the safety/mode card.

  Extracted verbatim from `DevIdeWeb.WorkspaceLive.Show`.
  """

  use DevIdeWeb, :html

  def render_agents(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-3 overflow-auto pr-1">
      {render_pairing_card(assigns)}
      {render_preview_environments_card(assigns)}
      {render_safety_card(assigns)}
      {render_agent_worktrees(assigns)}
      <div class="rounded border border-amber-300 bg-amber-50 p-3 text-xs text-amber-900">
        <strong>Write mode: disabled.</strong>
        Agent attach is read-only. Phoenix does not start agents, send prompts, or grant write access.
      </div>
      <div class="flex justify-end">
        <button phx-click="agents:refresh" class="text-xs rounded border px-2 py-1">↻ refresh</button>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-2 2xl:grid-cols-3 gap-3">
        <%= for cap <- @agent_caps do %>
          <div class="border rounded p-3">
            <div class="flex justify-between items-baseline">
              <h3 class="font-medium">{cap_label(cap.kind)}</h3>
              <span class={cap_status_class(cap.status)}>{cap.status}</span>
            </div>
            <%= if cap.status == :detected do %>
              <dl class="text-xs text-zinc-600 space-y-0.5 mt-1">
                <div>source: {cap.source}</div>
                <%= if cap.path do %>
                  <div class="font-mono">path: {cap.path}</div>
                <% end %>
                <%= if cap.url do %>
                  <div class="font-mono">url: {cap.url}</div>
                  <%= if cap.kind == :tidewave do %>
                    <div class="mt-1 flex flex-wrap gap-1.5">
                      <a
                        id="agent-cap-tidewave-open"
                        href={cap.url}
                        target="_blank"
                        rel="noopener"
                        class="inline-flex items-center rounded border border-blue-200 bg-blue-50 px-2 py-1 font-sans text-[11px] font-medium text-blue-700 transition hover:border-blue-300 hover:bg-blue-100"
                      >
                        Open Tidewave
                      </a>
                      <button
                        type="button"
                        phx-click="preview:open"
                        phx-value-surface="tidewave-local"
                        class="inline-flex items-center rounded border border-violet-200 bg-violet-50 px-2 py-1 font-sans text-[11px] font-medium text-violet-700 transition hover:border-violet-300 hover:bg-violet-100"
                      >
                        Open in preview pane
                      </button>
                    </div>
                  <% end %>
                <% end %>
                <%= if cap.kind == :tidewave do %>
                  <%= if mcp_url = tidewave_mcp_url(cap, assigns) do %>
                    <div class="font-mono">mcp_url: {mcp_url}</div>
                  <% end %>
                <% end %>
                <%= if cap.mtime do %>
                  <div>updated: {NaiveDateTime.to_string(cap.mtime)}</div>
                <% end %>
                <%= if cap.details != %{} do %>
                  <div class="font-mono text-zinc-400">{inspect(cap.details)}</div>
                <% end %>
              </dl>
            <% else %>
              <p class="text-xs text-zinc-500 mt-1">not detected</p>
            <% end %>
          </div>
        <% end %>
      </div>

      {render_pending_annotations(assigns)}
      {render_workspace_operator_notifications(assigns)}
      {render_mcp_activity(assigns)}
      {render_preview_activity(assigns)}

      <div class="border rounded p-3 space-y-2">
        <h3 class="font-medium">Agent Runs (review mode)</h3>
        <p class="text-xs text-zinc-500">
          Phoenix may start an allowlisted, write-free command and observe its output.
          No prompts, no patches, no Apply path.
        </p>
        <%= if @agent_run_error do %>
          <p class="text-xs text-red-700">{@agent_run_error}</p>
        <% end %>
        <%= if @agent_review_cmds == [] do %>
          <p class="text-xs text-zinc-500">
            No review commands available — required capabilities not detected.
          </p>
        <% else %>
          <div class="flex flex-wrap gap-2">
            <%= for cmd <- @agent_review_cmds do %>
              <button
                phx-click="agent_run:start"
                phx-value-id={cmd.id}
                disabled={@agent_run && @agent_run.status == :running}
                title={cmd.description}
                class="text-xs rounded border px-2 py-1 disabled:opacity-50"
              >
                ▶ {cmd.id}
              </button>
            <% end %>
            <%= if @agent_run && @agent_run.status == :running do %>
              <button
                phx-click="agent_run:cancel"
                class="text-xs rounded border px-2 py-1 text-red-700"
              >
                cancel
              </button>
            <% end %>
          </div>
        <% end %>
        <%= if @agent_run do %>
          <div class="text-xs font-mono text-zinc-500 flex flex-wrap gap-3">
            <span>{Enum.join(@agent_run.argv, " ")}</span>
            <span class={cap_status_class(@agent_run.status)}>{@agent_run.status}</span>
            <%= if @agent_run.exit_code != nil do %>
              <span>exit={inspect(@agent_run.exit_code)}</span>
            <% end %>
            <%= if @agent_run.started_at do %>
              <span>started {DateTime.to_string(@agent_run.started_at)}</span>
            <% end %>
            <%= if @agent_run.finished_at do %>
              <span>finished {DateTime.to_string(@agent_run.finished_at)}</span>
            <% end %>
          </div>
          <pre class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded max-h-72 overflow-auto whitespace-pre-wrap">{@agent_run.buffer}</pre>
        <% end %>
      </div>

      {render_proposals(assigns)}

      <div class="border rounded p-3">
        <h3 class="font-medium mb-2">Recent agent transcripts (read-only)</h3>
        <ul id="agent-transcripts" phx-update="stream" class="text-xs space-y-1">
          <li id="agent-transcripts-empty" class="hidden only:block text-zinc-500">
            No transcripts found.
          </li>
          <%= for {dom_id, a} <- @streams.agent_transcripts do %>
            <li id={dom_id} class="font-mono flex justify-between">
              <button
                phx-click="tree:open"
                phx-value-path={a.rel_path}
                class="hover:underline text-left flex-1 truncate"
              >
                {a.rel_path}
              </button>
              <span class="text-zinc-500 ml-2">
                {a.size}b {if a.mtime, do: "· " <> NaiveDateTime.to_string(a.mtime)}
              </span>
            </li>
          <% end %>
        </ul>
      </div>
    </section>
    """
  end

  defp render_agent_worktrees(assigns) do
    ~H"""
    <div id="agent-worktrees" class="rounded border border-base-300 bg-base-100 p-3 space-y-2">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <div>
          <h3 class="font-medium">Agent Worktrees</h3>
          <p class="text-xs text-zinc-500">
            Branch checkouts created by agents stay under this workspace, not in the main picker.
          </p>
        </div>
        <span class="rounded-full bg-base-200 px-2 py-0.5 text-[11px] text-base-content/60">
          {length(@agent_worktrees)} tracked
        </span>
      </div>

      <%= if @agent_worktrees == [] do %>
        <p class="text-xs text-zinc-500">
          No reported agent worktrees yet. Agents can report one after creating a Git worktree.
        </p>
      <% else %>
        <ul class="space-y-2">
          <%= for wt <- @agent_worktrees do %>
            <li
              id={"agent-worktree-" <> wt.runtime_id}
              class="rounded border border-base-300/80 bg-base-100 px-3 py-2 text-xs"
            >
              <div class="flex flex-wrap items-start justify-between gap-2">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="font-medium text-base-content">{worktree_agent_label(wt)}</span>
                    <span class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[11px] text-base-content/70">
                      {worktree_branch_label(wt)}
                    </span>
                    <span class={worktree_status_class(wt.status)}>{wt.status}</span>
                  </div>
                  <div class="mt-1 truncate font-mono text-[11px] text-zinc-500" title={wt.path}>
                    {wt.path_label}
                  </div>
                  <div class="mt-1 flex flex-wrap gap-2 font-mono text-[10px] text-zinc-400">
                    <span :if={wt.git_head_sha}>{wt.git_head_sha}</span>
                    <span :if={wt.git_detached?}>detached</span>
                    <span :if={wt.last_active_at}>seen {wt.last_active_at}</span>
                  </div>
                </div>
                <div class="flex shrink-0 flex-wrap gap-1.5">
                  <button
                    type="button"
                    phx-click="agent_worktree:compare"
                    phx-value-runtime-id={wt.runtime_id}
                    class="rounded border border-base-300 bg-base-100 px-2 py-1 text-[11px] font-medium text-base-content/70 transition hover:bg-base-200"
                  >
                    Compare
                  </button>
                  <button
                    type="button"
                    phx-click="agent_worktree:attach"
                    phx-value-runtime-id={wt.runtime_id}
                    class="rounded border border-sky-300 bg-sky-50 px-2 py-1 text-[11px] font-medium text-sky-800 transition hover:bg-sky-100"
                  >
                    Attach shell
                  </button>
                </div>
              </div>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end

  defp worktree_agent_label(%{agent: agent}) when is_binary(agent) and agent != "", do: agent
  defp worktree_agent_label(_), do: "agent"

  defp worktree_branch_label(%{branch: branch}) when is_binary(branch) and branch != "",
    do: branch

  defp worktree_branch_label(_), do: "branch unknown"

  defp worktree_status_class("clean"),
    do: "rounded bg-emerald-50 px-1.5 py-0.5 text-[11px] font-medium text-emerald-700"

  defp worktree_status_class("dirty"),
    do: "rounded bg-amber-50 px-1.5 py-0.5 text-[11px] font-medium text-amber-700"

  defp worktree_status_class(_),
    do: "rounded bg-zinc-100 px-1.5 py-0.5 text-[11px] font-medium text-zinc-600"

  defp render_preview_environments_card(assigns) do
    ~H"""
    <div
      :if={@preview_environments != []}
      id="preview-environments-card"
      class="rounded border border-violet-200 bg-violet-50/50 p-3 text-xs text-violet-950 space-y-2"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h3 class="font-medium text-sm text-violet-900">Preview environments</h3>
        <span class="rounded-full bg-violet-100 px-2 py-0.5 text-[10px] font-medium text-violet-800">
          {length(@preview_environments)} running
        </span>
      </div>
      <p class="text-violet-800/90">
        Ephemeral DevIDE instances from <span class="font-mono">scripts/preview-env.sh</span>.
        Tidewave MCP is available on each loopback port.
      </p>
      <ul class="space-y-2">
        <%= for env <- @preview_environments do %>
          <li class="rounded border border-violet-200/80 bg-white/70 px-3 py-2">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <span class="font-mono font-medium text-violet-950">{env.id}</span>
              <span class="text-[10px] text-violet-600">
                {preview_env_kind_label(env.kind)} · port {env.port}
              </span>
            </div>
            <div class="mt-1 flex flex-wrap gap-1.5">
              <button
                type="button"
                phx-click="preview:open"
                phx-value-surface="tidewave-local"
                class="rounded border border-violet-300 bg-violet-50 px-2 py-1 text-[11px] font-medium text-violet-800 hover:bg-violet-100"
              >
                Open Tidewave
              </button>
              <%= if env[:tidewave_url] do %>
                <a
                  href={env.tidewave_url}
                  target="_blank"
                  rel="noopener"
                  class="rounded border border-violet-200 bg-white px-2 py-1 text-[11px] font-medium text-violet-700 hover:bg-violet-50"
                >
                  Browser
                </a>
              <% end %>
            </div>
            <%= if env[:tidewave_mcp_url] do %>
              <div class="mt-1 truncate font-mono text-[10px] text-violet-700/80">
                mcp: {env.tidewave_mcp_url}
              </div>
            <% end %>
          </li>
        <% end %>
      </ul>
      <%= if @resolved_tidewave_mcp_url do %>
        <div class="truncate font-mono text-[10px] text-violet-700/80">
          resolved tidewave_mcp_url: {@resolved_tidewave_mcp_url}
        </div>
      <% end %>
    </div>
    """
  end

  defp preview_env_kind_label("dirty"), do: "working tree"
  defp preview_env_kind_label("ref"), do: "committed ref"
  defp preview_env_kind_label(kind) when is_binary(kind), do: kind
  defp preview_env_kind_label(_), do: "preview"

  defp tidewave_mcp_url(cap, assigns) do
    details = cap.details || %{}

    Map.get(details, :mcp_url) ||
      Map.get(details, "mcp_url") ||
      assigns[:resolved_tidewave_mcp_url]
  end

  defp render_pairing_card(assigns) do
    ~H"""
    <div
      id="agent-pairing-card"
      class="rounded border border-sky-200 bg-sky-50/60 p-3 text-xs text-sky-950 space-y-2"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <h3 class="font-medium text-sm text-sky-900">Side-by-side pairing</h3>
          <span class={pairing_health_class(@agent_caps)}>
            {pairing_health_label(@agent_caps)}
          </span>
        </div>
        <div class="flex flex-wrap gap-1.5">
          <button
            id="agent-pairing-apply-template"
            type="button"
            phx-click="tmux:apply_template"
            phx-value-template-id="agent_pair"
            class="rounded border border-sky-300 bg-white px-2 py-1 text-[11px] font-medium text-sky-800 hover:bg-sky-100"
          >
            Apply Agent Pair layout
          </button>
          <button
            id="agent-preview-demo-apply-template"
            type="button"
            phx-click="tmux:apply_template"
            phx-value-template-id="agent_preview_demo"
            class="rounded border border-violet-300 bg-white px-2 py-1 text-[11px] font-medium text-violet-800 hover:bg-violet-50"
          >
            Apply Preview Demo
          </button>
        </div>
      </div>
      <p class="text-sky-800/90">
        You work in the focused operator pane. External agents should call terminal MCP
        with <span class="font-mono">workspace_id={@workspace.id}</span>, read <span class="font-mono">terminal_topology</span>, and target the
        <span class="font-mono">agent</span>
        pane — not your focused pane.
      </p>
      <dl class="grid gap-1 font-mono text-[10px] text-sky-900/80">
        <div>session: <span class="text-sky-950">{@tmux_session}</span></div>
        <%= if cap = Enum.find(@agent_caps, &(&1.kind == :terminal_mcp and &1.status == :detected)) do %>
          <div class="truncate">
            terminal_mcp: <a href={cap.url} class="underline">{cap.url}</a>
          </div>
        <% end %>
        <%= if cap = Enum.find(@agent_caps, &(&1.kind == :preview_mcp and &1.status == :detected)) do %>
          <div class="truncate">
            preview_mcp: <a href={cap.url} class="underline">{cap.url}</a>
          </div>
        <% end %>
      </dl>
      <%= if Enum.find(@agent_caps, &(&1.kind == :terminal_mcp and &1.status == :detected)) == nil or
             Enum.find(@agent_caps, &(&1.kind == :preview_mcp and &1.status == :detected)) == nil do %>
        <p class="text-amber-800">
          MCP endpoints missing — set <span class="font-mono">DEV_IDE_API_TOKEN</span>
          and restart DevIDE.
        </p>
      <% end %>
    </div>
    """
  end

  defp render_mcp_activity(assigns) do
    ~H"""
    <div id="agent-mcp-activity" class="border rounded p-3 space-y-2">
      <h3 class="font-medium">Live MCP activity</h3>
      <p class="text-xs text-zinc-500">
        Recent terminal and preview MCP tool calls from external agents. Click a row with a
        session or pane to jump there.
      </p>
      <%= if @agent_mcp_activity == [] do %>
        <p class="text-xs text-zinc-500">No MCP calls yet for this workspace.</p>
      <% else %>
        <ul class="space-y-1 text-xs max-h-48 overflow-auto">
          <%= for entry <- @agent_mcp_activity do %>
            <li id={"agent-mcp-activity-" <> entry.id}>
              <%= if mcp_activity_focusable?(entry) do %>
                <button
                  type="button"
                  phx-click="agent_mcp_activity:focus"
                  phx-value-session={activity_meta(entry.metadata, :session)}
                  phx-value-pane={activity_meta(entry.metadata, :pane)}
                  class={[
                    "flex w-full flex-wrap items-baseline gap-x-2 gap-y-0.5 rounded px-2 py-1 text-left font-mono transition hover:ring-1 hover:ring-sky-200",
                    entry.status == :error && "bg-red-50 ring-1 ring-red-200",
                    entry.status != :error && "bg-zinc-50"
                  ]}
                  title="Focus session/pane"
                >
                  {render_mcp_activity_row(%{entry: entry})}
                </button>
              <% else %>
                <div class={[
                  "flex flex-wrap items-baseline gap-x-2 gap-y-0.5 rounded px-2 py-1 font-mono",
                  entry.status == :error && "bg-red-50 ring-1 ring-red-200",
                  entry.status != :error && "bg-zinc-50"
                ]}>
                  {render_mcp_activity_row(%{entry: entry})}
                </div>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end

  defp mcp_status_class(:ok), do: "text-emerald-700"
  defp mcp_status_class(:error), do: "text-red-700"
  defp mcp_status_class(_), do: "text-zinc-500"

  defp render_mcp_activity_row(assigns) do
    ~H"""
    <span class={mcp_status_class(@entry.status)}>{@entry.source}</span>
    <span class="text-zinc-800">{@entry.tool}</span>
    <span class="min-w-0 flex-1 truncate text-zinc-500">{@entry.summary}</span>
    <span class="text-zinc-400">{format_activity_time(@entry.inserted_at)}</span>
    """
  end

  defp render_preview_activity_row(assigns) do
    ~H"""
    <span class={preview_activity_source_class(@entry.source)}>{@entry.source}</span>
    <span class="text-zinc-800">{@entry.event}</span>
    <span class="min-w-0 flex-1 truncate text-zinc-500">{@entry.summary}</span>
    <span class="text-zinc-400">{format_activity_time(@entry.inserted_at)}</span>
    """
  end

  defp render_pending_annotations(assigns) do
    ~H"""
    <div
      :if={@pending_annotations != []}
      id="pending-annotations"
      class="rounded border border-amber-200 bg-amber-50/70 p-3 space-y-2 text-xs text-amber-950"
    >
      <h3 class="font-medium text-sm text-amber-900">Pending agent annotations</h3>
      <p class="text-amber-800/80">
        External agents proposed notes that need your review.
      </p>
      <ul class="space-y-2">
        <%= for annotation <- @pending_annotations do %>
          <li
            id={"pending-annotation-" <> annotation.id}
            class="rounded border border-amber-200/80 bg-white/80 px-3 py-2"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <span class="rounded bg-amber-100 px-1.5 py-0.5 font-mono text-[10px] text-amber-800">
                {annotation.author_type}
              </span>
              <span class="font-mono text-[10px] text-amber-500">
                {format_activity_time(annotation.inserted_at)}
              </span>
            </div>
            <p class="mt-1 whitespace-pre-wrap text-amber-950">{annotation.content}</p>
            <div class="mt-2 flex flex-wrap gap-1.5">
              <button
                type="button"
                phx-click="annotation:approve"
                phx-value-id={annotation.id}
                class="rounded border border-emerald-300 bg-emerald-50 px-2 py-1 text-[11px] font-medium text-emerald-800 hover:bg-emerald-100"
              >
                Approve
              </button>
              <button
                type="button"
                phx-click="annotation:reject"
                phx-value-id={annotation.id}
                class="rounded border border-red-300 bg-red-50 px-2 py-1 text-[11px] font-medium text-red-800 hover:bg-red-100"
              >
                Reject
              </button>
              <%= if annotation.file_path do %>
                <button
                  type="button"
                  phx-click="annotation:open"
                  phx-value-path={annotation.file_path}
                  class="rounded border border-amber-300 bg-white px-2 py-1 text-[11px] font-medium text-amber-900 hover:bg-amber-100"
                >
                  Open file
                </button>
              <% end %>
            </div>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp render_workspace_operator_notifications(assigns) do
    ~H"""
    <div
      :if={@workspace_operator_notifications != []}
      id="workspace-operator-notifications"
      class="rounded border border-indigo-200 bg-indigo-50/60 p-3 space-y-2 text-xs text-indigo-950"
    >
      <h3 class="font-medium text-sm text-indigo-900">Delegated task updates</h3>
      <p class="text-indigo-800/80">
        Recent fleet notifications for this workspace. Full history lives on the Fleet page.
      </p>
      <ul class="space-y-1.5">
        <%= for notification <- @workspace_operator_notifications do %>
          <li
            id={"workspace-operator-notification-" <> notification.id}
            class="rounded bg-white/70 px-2 py-1.5"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <span class="font-medium text-indigo-900">{notification.message}</span>
              <span class="font-mono text-[10px] text-indigo-400">
                {format_activity_time(notification.occurred_at)}
              </span>
            </div>
            <div class="mt-0.5 flex flex-wrap gap-2 font-mono text-[10px] text-indigo-600/80">
              <span class={operator_notification_kind_class(notification.kind)}>
                {notification.kind}
              </span>
              <span :if={notification.assignment_id}>
                assignment {short_notification_id(notification.assignment_id)}
              </span>
            </div>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp render_preview_activity(assigns) do
    ~H"""
    <div id="agent-preview-activity" class="border rounded p-3 space-y-2">
      <h3 class="font-medium">Preview activity</h3>
      <p class="text-xs text-zinc-500">
        Recent preview pane events from agents, MCP, and browser interaction.
      </p>
      <%= if @preview_activity == [] do %>
        <p class="text-xs text-zinc-500">No preview activity yet for this workspace.</p>
      <% else %>
        <ul class="space-y-1 text-xs max-h-40 overflow-auto">
          <%= for entry <- @preview_activity do %>
            <li id={"agent-preview-activity-" <> entry.id}>
              <%= if is_binary(entry.pane_id) and entry.pane_id != "" do %>
                <button
                  type="button"
                  phx-click="preview_activity:focus"
                  phx-value-pane-id={entry.pane_id}
                  class="flex w-full flex-wrap items-baseline gap-x-2 gap-y-0.5 rounded bg-violet-50 px-2 py-1 text-left font-mono transition hover:ring-1 hover:ring-violet-200"
                  title="Focus preview pane"
                >
                  {render_preview_activity_row(%{entry: entry})}
                </button>
              <% else %>
                <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5 rounded bg-violet-50 px-2 py-1 font-mono">
                  {render_preview_activity_row(%{entry: entry})}
                </div>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end

  defp operator_notification_kind_class(:failed),
    do: "rounded bg-red-100 px-1.5 py-0.5 text-red-700"

  defp operator_notification_kind_class(:completed),
    do: "rounded bg-emerald-100 px-1.5 py-0.5 text-emerald-700"

  defp operator_notification_kind_class(:stale),
    do: "rounded bg-amber-100 px-1.5 py-0.5 text-amber-700"

  defp operator_notification_kind_class(_),
    do: "rounded bg-indigo-100 px-1.5 py-0.5 text-indigo-700"

  defp preview_activity_source_class(:mcp), do: "text-violet-700"
  defp preview_activity_source_class(:browser), do: "text-sky-700"
  defp preview_activity_source_class(:preview_control), do: "text-emerald-700"
  defp preview_activity_source_class(:preview_pane), do: "text-amber-700"
  defp preview_activity_source_class(_), do: "text-zinc-500"

  defp short_notification_id(id) when is_binary(id) do
    if String.length(id) > 8, do: String.slice(id, 0, 8) <> "…", else: id
  end

  defp mcp_activity_focusable?(entry) do
    session = activity_meta(entry.metadata, :session)
    pane = activity_meta(entry.metadata, :pane)
    (is_binary(session) and session != "") or (is_binary(pane) and pane != "")
  end

  defp activity_meta(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp activity_meta(_, _), do: nil

  defp pairing_health_label(caps) do
    case pairing_health(caps) do
      :ok -> "MCP ready"
      :partial -> "MCP partial"
      :missing -> "MCP missing"
    end
  end

  defp pairing_health_class(caps) do
    base = "rounded-full px-2 py-0.5 text-[10px] font-medium"

    case pairing_health(caps) do
      :ok -> base <> " bg-emerald-100 text-emerald-800"
      :partial -> base <> " bg-amber-100 text-amber-800"
      :missing -> base <> " bg-red-100 text-red-800"
    end
  end

  defp pairing_health(caps) do
    terminal? = Enum.any?(caps, &(&1.kind == :terminal_mcp and &1.status == :detected))
    preview? = Enum.any?(caps, &(&1.kind == :preview_mcp and &1.status == :detected))

    cond do
      terminal? and preview? -> :ok
      terminal? or preview? -> :partial
      true -> :missing
    end
  end

  defp format_activity_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp render_proposals(assigns) do
    ~H"""
    <div class="border rounded p-3 space-y-2">
      <h3 class="font-medium">Proposal Review</h3>
      <p class="text-xs text-zinc-500">
        Review only. To apply a proposal, copy it or use terminal/git manually.
      </p>
      <%= if @proposals_count == 0 do %>
        <p class="text-xs text-zinc-500">No proposals discovered.</p>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-[260px_1fr] gap-3">
          <ul id="proposals" phx-update="stream" class="text-xs space-y-1 max-h-72 overflow-auto">
            <%= for {dom_id, p} <- @streams.proposals do %>
              <li id={dom_id}>
                <button
                  phx-click="proposal:select"
                  phx-value-path={p.rel_path}
                  class={"w-full text-left rounded px-1 py-0.5 hover:bg-zinc-100 " <> if @selected_proposal && @selected_proposal.rel_path == p.rel_path, do: "bg-zinc-200", else: ""}
                >
                  <span class="font-mono truncate block">{p.rel_path}</span>
                  <span class="text-zinc-500">
                    {p.size}b {if p.mtime, do: "· " <> NaiveDateTime.to_string(p.mtime)}
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
          <div class="border rounded p-2 min-h-[12rem]">
            <%= if @selected_proposal do %>
              {render_proposal_detail(assigns, @selected_proposal)}
            <% else %>
              <p class="text-xs text-zinc-500">Select a proposal to preview.</p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_proposal_detail(assigns, proposal) do
    _ = assigns.proposal_analysis
    git_paths = MapSet.new(assigns.git_status, & &1.path)
    proposal_paths = MapSet.new(proposal.changes, & &1.path)

    in_both = MapSet.intersection(git_paths, proposal_paths) |> MapSet.to_list() |> Enum.sort()

    only_proposal =
      MapSet.difference(proposal_paths, git_paths) |> MapSet.to_list() |> Enum.sort()

    only_workspace =
      MapSet.difference(git_paths, proposal_paths) |> MapSet.to_list() |> Enum.sort()

    assigns =
      assigns
      |> Map.put(:p, proposal)
      |> Map.put(:in_both, in_both)
      |> Map.put(:only_proposal, only_proposal)
      |> Map.put(:only_workspace, only_workspace)

    ~H"""
    <div class="space-y-2 text-xs">
      <div class="flex justify-between font-mono">
        <span class="truncate">{@p.rel_path}</span>
        <button phx-click="proposal:clear" class="rounded border px-1.5">close</button>
      </div>
      <dl class="text-zinc-600 space-y-0.5">
        <div>parser: {@p.parser}</div>
        <div>
          status: <span class={proposal_status_class(@p.status)}>{@p.status}</span>
          <%= if @p.truncated do %>
            · (preview truncated)
          <% end %>
        </div>
        <%= if @p.size > 0 do %>
          <div>size: {@p.size}b</div>
        <% end %>
        <%= if @p.mtime do %>
          <div>mtime: {NaiveDateTime.to_string(@p.mtime)}</div>
        <% end %>
        <%= if @p.error do %>
          <div class="text-red-700">error: {@p.error}</div>
        <% end %>
      </dl>

      <%= if @proposal_analysis do %>
        <div class="border rounded p-2 bg-zinc-50 space-y-1">
          <div class="flex items-center gap-2">
            <strong>Conflict analysis:</strong>
            <span class={analysis_class(@proposal_analysis.risk)}>
              {@proposal_analysis.risk}
            </span>
            <span class="text-zinc-500">— {@proposal_analysis.reason}</span>
          </div>
          <%= if @proposal_analysis.overlapping_files != [] do %>
            <div>
              <span class="text-zinc-500">overlapping files:</span>
              <ul class="font-mono ml-3 list-disc">
                <%= for f <- @proposal_analysis.files,
                        f.status in [:overlap, :conflict] do %>
                  <li>
                    {f.status} · {f.path}
                    <%= if f.hunks != [] do %>
                      <ul class="text-zinc-500 ml-3 list-square">
                        <%= for o <- f.hunks do %>
                          <li>
                            proposal hunk @{elem(o.proposal.old_range, 0)},{elem(
                              o.proposal.old_range,
                              1
                            )} ↔ workspace @{elem(o.workspace.old_range, 0)},{elem(
                              o.workspace.old_range,
                              1
                            )}
                          </li>
                        <% end %>
                      </ul>
                    <% end %>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @p.status == :parsed do %>
        <div>
          <strong>Changed files in proposal:</strong>
          <ul class="font-mono ml-3 list-disc">
            <%= for c <- @p.changes do %>
              <li>{c.kind} · {c.path}</li>
            <% end %>
          </ul>
        </div>

        <div class="grid grid-cols-3 gap-2">
          <div>
            <strong class="block">In both</strong>
            <%= if @in_both == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @in_both do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
          <div>
            <strong class="block">Proposal only</strong>
            <%= if @only_proposal == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @only_proposal do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
          <div>
            <strong class="block">Workspace only</strong>
            <%= if @only_workspace == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @only_workspace do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
        </div>

        <%= if @p.diff do %>
          <details>
            <summary class="cursor-pointer">unified diff preview</summary>
            <pre class="bg-zinc-950 text-zinc-100 p-2 rounded mt-1 overflow-auto max-h-72 whitespace-pre-wrap">{@p.diff}</pre>
          </details>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp analysis_class(:clean), do: "text-green-700"
  defp analysis_class(:overlap), do: "text-amber-700"
  defp analysis_class(:conflict), do: "text-red-700"
  defp analysis_class(_), do: "text-zinc-500"

  defp proposal_status_class(:parsed), do: "text-green-700"
  defp proposal_status_class(:invalid), do: "text-red-700"
  defp proposal_status_class(:too_large), do: "text-amber-700"
  defp proposal_status_class(_), do: "text-zinc-500"

  defp render_safety_card(assigns) do
    ~H"""
    <div class="border rounded p-3 bg-zinc-50">
      <h3 class="font-medium mb-2">Workspace safety</h3>
      <dl class="grid grid-cols-2 gap-y-1 text-xs">
        <dt class="text-zinc-500">mode</dt>
        <dd class="flex items-center gap-2">
          <span class="font-mono">{@workspace_mode}</span>
          <span class="text-zinc-500">({@workspace_mode_source})</span>
          <%= if @can_set_workspace_mode? do %>
            <.form for={%{}} phx-change="workspace:set_mode" class="inline-flex">
              <select name="mode" class="border rounded px-1 py-0 text-xs">
                <%= for m <- DevIDE.Policy.WorkspaceMode.valid_modes() do %>
                  <option value={Atom.to_string(m)} selected={m == @workspace_mode}>
                    {m}
                  </option>
                <% end %>
              </select>
            </.form>
          <% end %>
        </dd>
        <dt class="text-zinc-500">role</dt>
        <dd>
          <span class="font-mono">{@workspace_role}</span>
          <%= unless @can_set_workspace_mode? do %>
            <span class="text-zinc-500">— safety controls hidden</span>
          <% end %>
        </dd>
        <dt class="text-zinc-500">deploy</dt>
        <dd class="space-y-0.5">
          <div class="font-mono text-[10px]">
            {short_revision(@deployment_panel.revision)}
            <%= if @deployment_panel.draining? do %>
              <span class="text-amber-700">draining</span>
            <% else %>
              <span class="text-green-700">serving</span>
            <% end %>
          </div>
          <%= if is_integer(@deployment_panel.active_liveviews) do %>
            <div class="text-[10px] text-zinc-500">
              {@deployment_panel.active_liveviews} active LiveViews
            </div>
          <% end %>
        </dd>
        <%= if @workspace_record && @workspace_record.last_seen_at do %>
          <dt class="text-zinc-500">last sync</dt>
          <dd class="font-mono text-[10px]">{DateTime.to_iso8601(@workspace_record.last_seen_at)}</dd>
        <% end %>
        <dt class="text-zinc-500">db isolation</dt>
        <dd>
          <span class={isolation_class(@db_isolation.isolation)}>{@db_isolation.isolation}</span>
          <%= if @db_isolation.source != :none do %>
            <span class="text-zinc-500">· {@db_isolation.source}</span>
          <% end %>
          <%= if @db_isolation.summary do %>
            <span class="font-mono text-zinc-700">· {@db_isolation.summary}</span>
          <% end %>
          <button phx-click="isolation:refresh" class="text-[10px] rounded border px-1 ml-1">
            ↻
          </button>
          <%= if @db_isolation.detected_at do %>
            <div class="text-[10px] text-zinc-400">
              at {DateTime.to_iso8601(@db_isolation.detected_at)}
            </div>
          <% end %>
        </dd>
        <dt class="text-zinc-500">agent write</dt>
        <dd>
          <span class="text-red-700">disabled</span>
          <span class="text-zinc-500">
            — {agent_write_reason_full(@workspace_mode, @db_isolation.isolation)}
          </span>
        </dd>
        <dt class="text-zinc-500">proposal apply</dt>
        <dd>
          <span class="text-red-700">disabled</span>
          <span class="text-zinc-500">— not implemented</span>
        </dd>
        <%= if @last_decision do %>
          <dt class="text-zinc-500">last decision</dt>
          <dd class="font-mono text-zinc-700">
            {@last_decision.action} · {@last_decision.verdict}
            {if @last_decision.reason, do: "· " <> Atom.to_string(@last_decision.reason)}
          </dd>
        <% end %>
      </dl>
    </div>
    """
  end

  defp agent_write_reason_full(_mode, :shared_stage), do: "shared Stage DB; refused by policy"
  defp agent_write_reason_full(_mode, :unsafe), do: "DB target looks unsafe; refused by policy"
  defp agent_write_reason_full(:shared_stage_guarded, _), do: "shared Stage DB; refused by policy"
  defp agent_write_reason_full(_, _), do: "agent write locked"

  defp isolation_class(:shared_stage), do: "text-red-700 font-mono"
  defp isolation_class(:unsafe), do: "text-red-700 font-mono"
  defp isolation_class(:ephemeral), do: "text-green-700 font-mono"
  defp isolation_class(:local), do: "text-amber-700 font-mono"
  defp isolation_class(_), do: "text-zinc-500 font-mono"

  defp short_revision(revision) when is_binary(revision) and byte_size(revision) > 12,
    do: String.slice(revision, 0, 12)

  defp short_revision(revision) when is_binary(revision), do: revision
  defp short_revision(_), do: "unknown"

  defp cap_label(:opencode), do: "OpenCode"
  defp cap_label(:tidewave), do: "Tidewave MCP"
  defp cap_label(:preview_mcp), do: "Preview MCP"
  defp cap_label(:terminal_mcp), do: "Terminal MCP"
  defp cap_label(:fff), do: "FFF MCP"
  defp cap_label(:browser_artifacts), do: "Browser artifacts"
  defp cap_label(:transcripts), do: "Transcripts"
  defp cap_label(other), do: to_string(other)

  defp cap_status_class(:detected), do: "text-green-700 text-xs"
  defp cap_status_class(:missing), do: "text-zinc-400 text-xs"

  # Markup lives in DevIdeWeb.WorkspaceLive.Show.LogsPanel (imported above);
  # this stays as the call-convention wrapper used by render/1.
end
