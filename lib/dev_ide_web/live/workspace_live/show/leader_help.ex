defmodule DevIdeWeb.WorkspaceLive.Show.LeaderHelp do
  @moduledoc false

  use DevIdeWeb, :html

  def leader_help_overlay(assigns) do
    assigns =
      Phoenix.Component.assign(assigns, :cheat_tabs, [
        %{id: "shortcuts", label: "Shortcuts"},
        %{id: "preview", label: "Preview"},
        %{id: "agents", label: "Agents"}
      ])

    ~H"""
    <div id="leader-cheatsheet" class="fixed inset-0 z-50 hidden">
      <div class="absolute inset-0 bg-black/30" phx-click={JS.hide(to: "#leader-cheatsheet")}></div>
      <div class="absolute top-1/2 left-1/2 max-h-[80vh] w-[30rem] max-w-[92vw] -translate-x-1/2 -translate-y-1/2 overflow-auto rounded border border-base-300 bg-base-100 p-4 text-xs shadow-xl">
        <h2 class="mb-2 text-sm font-semibold">Help</h2>
        <div role="tablist" class="mb-3 flex gap-1 border-b border-base-300">
          <button
            :for={{tab, i} <- Enum.with_index(@cheat_tabs)}
            type="button"
            role="tab"
            id={"cheat-tab-#{tab.id}"}
            data-cheat-tab
            aria-selected={to_string(i == 0)}
            aria-controls={"cheat-panel-#{tab.id}"}
            phx-click={switch_cheat_tab(tab.id)}
            class="-mb-px border-b-2 border-transparent px-2 py-1 text-xs font-medium text-base-content/50 hover:text-base-content/80 aria-selected:border-primary aria-selected:text-base-content"
          >
            {tab.label}
          </button>
        </div>
        <div
          id="cheat-panel-shortcuts"
          data-cheat-panel
          role="tabpanel"
          aria-labelledby="cheat-tab-shortcuts"
        >
          <p class="mb-1 text-[11px] text-base-content/60">
            Press <kbd>Ctrl + B</kbd>, then the key shown below. Works from anywhere, even inside the terminal.
          </p>
          <p class="mb-3 text-[11px] text-base-content/60">
            No need to memorize these — a paired agent can do all of it for you in plain
            English: "merge windows 5 and 6 side by side", "rename this pane",
            "move this pane to its own window". See the <em>Agents</em> tab.
          </p>
          <div class="grid grid-cols-2 gap-x-6 gap-y-1">
            <div class="font-semibold text-base-content/60 col-span-2 mt-1">Sessions & windows</div>
            <.cheat_row keys="s" desc="pick a session" />
            <.cheat_row keys="w" desc="pick a window" />
            <.cheat_row keys="( / )" desc="previous or next session" />
            <.cheat_row keys="c" desc="open a new window" />
            <.cheat_row keys="C" desc="new window in a new browser tab" />
            <.cheat_row keys="n / p" desc="next or previous window" />
            <.cheat_row keys="l" desc="jump back to your last window" />
            <.cheat_row keys="1–9" desc="jump to window 1–9" />
            <.cheat_row keys="," desc="rename this window" />
            <.cheat_row keys="$" desc="rename this session" />
            <.cheat_row keys="&" desc="close this window" />
            <.cheat_row keys="y" desc="copy a link to this session and window" />
            <.cheat_row keys="d" desc="return to the workspace shell" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">Panes</div>
            <.cheat_row keys="% or |" desc="split side by side" />
            <.cheat_row keys={"\" or -"} desc="split top and bottom" />
            <.cheat_row keys="← ↓ ↑ →" desc="move focus between panes" />
            <.cheat_row keys="o" desc="focus the next pane" />
            <.cheat_row keys=";" desc="focus your last pane" />
            <.cheat_row keys="z" desc="zoom this pane full screen" />
            <.cheat_row keys="x" desc="close this pane" />
            <.cheat_row keys="q" desc="show pane numbers — then press 0–9 to jump" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">More leader keys</div>
            <.cheat_row keys=":" desc="open the command palette" />
            <.cheat_row keys="?" desc="show this help" />
            <.cheat_row keys="Esc / Ctrl + B" desc="cancel (when waiting for a second key)" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">
              Inside a session or window picker
            </div>
            <.cheat_row keys="↑ ↓" desc="browse entries" />
            <.cheat_row keys="→ / ←" desc="expand or collapse a session's windows" />
            <.cheat_row keys="type" desc="filter the list — Backspace edits" />
            <.cheat_row keys="o" desc="open the focused entry in a new tab" />
            <.cheat_row keys="l" desc="copy a link to the focused entry" />
            <.cheat_row keys="r" desc="rename the focused window or session" />
            <.cheat_row keys="&" desc="kill the focused window (window picker)" />
            <.cheat_row keys="Enter" desc="attach to the focused entry" />
            <.cheat_row keys="Esc" desc="clear the filter, then close" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">
              From anywhere (no Ctrl + B)
            </div>
            <.cheat_row keys="Ctrl+P" desc="open the command palette" />
            <.cheat_row keys="Ctrl+Space" desc="open the command palette" />
            <.cheat_row keys="Ctrl+Shift+F" desc="hide the header for more terminal space" />
            <.cheat_row keys="Ctrl+← →" desc="previous or next pane" />
            <.cheat_row keys="Ctrl+↑ ↓" desc="previous or next session" />
            <.cheat_row keys="Space" desc="focus the terminal" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">
              Inside the command palette
            </div>
            <.cheat_row keys="Tab" desc="switch category (Files, Commands, Terminal, …)" />
            <.cheat_row keys="Shift+Tab" desc="previous category" />
            <.cheat_row keys="↑ ↓ Enter" desc="browse results and run the one you want" />
            <.cheat_row keys="Esc" desc="close the palette" />
          </div>
          <p class="mt-3 text-[10px] text-base-content/50">
            More detail in <code>docs/leader_keys.md</code>
          </p>
        </div>
        <div
          id="cheat-panel-preview"
          data-cheat-panel
          role="tabpanel"
          aria-labelledby="cheat-tab-preview"
          class="hidden"
        >
          <p class="mb-3 text-[11px] text-base-content/60">
            A browser pane for your workspace apps — run a dev server, then preview it
            right inside DevIDE: click, type, navigate, screenshot.
          </p>
          <div class="grid grid-cols-[7rem_1fr] gap-x-3 gap-y-2">
            <.tip_row term="Open one">
              Palette → <em>Preview: Open Current Dev Server</em>
              (auto-detects your port),
              or run <code class="rounded bg-base-200 px-1 py-0.5">devide-preview :4000</code>
              in a terminal.
            </.tip_row>
            <.tip_row term="Localhost only">
              Previews load only your workspace's loopback ports. The port must be a common
              dev port, set in workspace metadata, or seen in your terminal output.
            </.tip_row>
            <.tip_row term="Framed apps">
              Apps that block embedding fall back to a built-in proxy automatically.
              Live-reload over WebSocket (HMR) won't tunnel through the proxy yet.
            </.tip_row>
            <.tip_row term="Stay logged in">
              Previews start fresh each session, so logins reset. Add
              <code class="rounded bg-base-200 px-1 py-0.5">--storage workspace</code>
              to keep auth across restarts.
            </.tip_row>
            <.tip_row term="Responsive">
              <code class="rounded bg-base-200 px-1 py-0.5">devide-preview :4000 --viewport 375x812</code>
              locks a device size.
            </.tip_row>
            <.tip_row term="Share">
              Add <code class="rounded bg-base-200 px-1 py-0.5">--share</code>
              so an agent or teammate can watch the same page.
            </.tip_row>
            <.tip_row term="Troubleshoot">
              <code class="rounded bg-base-200 px-1 py-0.5">preview errors &lt;session&gt;</code>
              shows console and connection problems. Previews track LiveView health and
              auto-reload on repeated socket failures.
            </.tip_row>
            <.tip_row term="After a restart">
              Re-open the preview — sessions live on the current instance.
            </.tip_row>
          </div>
          <p class="mt-3 text-[10px] text-base-content/50">
            More detail in <code>docs/subsystems/previews.md</code>
          </p>
        </div>
        <div
          id="cheat-panel-agents"
          data-cheat-panel
          role="tabpanel"
          aria-labelledby="cheat-tab-agents"
          class="hidden"
        >
          <p class="mb-3 text-[11px] text-base-content/60">
            DevIDE wires external coding agents into your workspace over MCP, giving them
            narrow, audited access to your tmux panes and previews. Pair one with <em>Agents tab → Apply Agent Pair layout</em>, then drive its pane.
          </p>
          <div class="grid grid-cols-[5rem_1fr] gap-x-3 gap-y-2">
            <.tip_row term="Claude">
              A bare <code class="rounded bg-base-200 px-1 py-0.5">claude</code>
              in a paired
              pane auto-loads DevIDE's terminal + preview MCP servers. It reads
              <code class="rounded bg-base-200 px-1 py-0.5">AGENTS.md</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">CLAUDE.md</code>
              first — keep your
              workspace notes and the push/deploy rules there. Strongest on long, multi-step
              changes and large context.
            </.tip_row>
            <.tip_row term="Grok">
              A bare <code class="rounded bg-base-200 px-1 py-0.5">grok</code>
              reads the project <code class="rounded bg-base-200 px-1 py-0.5">.mcp.json</code>
              DevIDE materializes,
              so it picks up the same MCP tools automatically. If the tools don't show up,
              refresh pairing to rewrite <code class="rounded bg-base-200 px-1 py-0.5">grok/config.toml</code>.
            </.tip_row>
            <.tip_row term="Codex">
              Codex gets DevIDE MCP through launch-time flags, not a project file — start
              <code class="rounded bg-base-200 px-1 py-0.5">codex</code>
              from the paired pane so
              the args apply, then confirm it lists the
              <code class="rounded bg-base-200 px-1 py-0.5">terminal</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">preview</code>
              servers before
              sending commands.
            </.tip_row>
            <.tip_row term="Sign in">
              By default, agents use the host's global Claude/Codex login. For an
              owner-isolated login instead, sign in once with
              <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth signin codex</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth signin claude</code>.
              DevIDE detects the owner from the current workspace; once signed in,
              matching workspaces share that owner login automatically. Use
              <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth status</code>
              to check sign-in state.
            </.tip_row>
            <.tip_row term="All three">
              Source <code class="rounded bg-base-200 px-1 py-0.5">.devbox-agent.env</code>
              first,
              and use <code class="rounded bg-base-200 px-1 py-0.5">.devbox-agent-prompt.txt</code>
              as a starter prompt. Drive an agent's pane with MCP
              <code class="rounded bg-base-200 px-1 py-0.5">terminal_send_command</code>
              / <code class="rounded bg-base-200 px-1 py-0.5">terminal_send_keys</code>.
            </.tip_row>
            <.tip_row term="Tmux chores">
              Agents can manage your windows and panes for you — ask in plain English to
              merge two windows into side-by-side panes, break a pane out into its own
              window, rename or renumber windows, or rebalance a layout. Every leader-key
              action on the <em>Shortcuts</em> tab is something an agent can run.
            </.tip_row>
          </div>
          <p class="mt-3 text-[10px] text-base-content/50">
            More detail in <code>docs/subsystems/agents.md</code>
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Build-to-scale: drives the help overlay's tab bar and its show/hide. Pure
  # client-side JS — no socket round-trip — so the overlay stays instant.
  defp switch_cheat_tab(id) do
    JS.set_attribute({"aria-selected", "false"}, to: "#leader-cheatsheet [data-cheat-tab]")
    |> JS.set_attribute({"aria-selected", "true"}, to: "#cheat-tab-#{id}")
    |> JS.add_class("hidden", to: "#leader-cheatsheet [data-cheat-panel]")
    |> JS.remove_class("hidden", to: "#cheat-panel-#{id}")
  end

  attr :keys, :string, required: true
  attr :desc, :string, required: true

  defp cheat_row(assigns) do
    ~H"""
    <kbd class="justify-self-start rounded bg-base-200 px-1.5 py-0.5 font-mono text-[10px]">
      {@keys}
    </kbd>
    <span class="text-base-content/80">{@desc}</span>
    """
  end

  attr :term, :string, required: true
  slot :inner_block, required: true

  defp tip_row(assigns) do
    ~H"""
    <div class="font-medium text-base-content/70">{@term}</div>
    <div class="text-base-content/80">{render_slot(@inner_block)}</div>
    """
  end
end
