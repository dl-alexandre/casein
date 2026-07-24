defmodule CaseinWeb.WorkspaceLive.Show.LeaderHelp do
  @moduledoc false

  use CaseinWeb, :html

  attr :connect_new_token, :string, default: nil
  attr :connect_mcp_json, :string, default: nil
  attr :connect_tokens, :list, default: []
  attr :connect_error, :string, default: nil
  attr :connect_info, :string, default: nil

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
            phx-click={cheat_tab_js(tab.id)}
            class="-mb-px border-b-2 border-transparent px-2 py-1 text-xs font-medium text-base-content/50 hover:text-base-content/80 aria-selected:border-primary aria-selected:text-base-content"
          >
            {tab.label}
          </button>
        </div>
        <p class="mb-3 text-[10px] text-base-content/50">
          <kbd class="rounded bg-base-200 px-1 py-0.5 font-mono">Esc</kbd>
          closes · <kbd class="rounded bg-base-200 px-1 py-0.5 font-mono">Tab</kbd>
          / <kbd class="rounded bg-base-200 px-1 py-0.5 font-mono">Shift+Tab</kbd>
          next section · <kbd class="rounded bg-base-200 px-1 py-0.5 font-mono">Ctrl+B ?</kbd>
          again also cycles tabs
        </p>
        <div
          id="cheat-panel-shortcuts"
          data-cheat-panel
          role="tabpanel"
          aria-labelledby="cheat-tab-shortcuts"
        >
          <p class="mb-1 text-[11px] text-base-content/60">
            Press <kbd class="rounded bg-base-200 px-1 py-0.5 font-mono">Ctrl + B</kbd>, then the key
            shown below. Works from anywhere, even inside the terminal. Use <strong>Ctrl</strong>, not Cmd — Cmd+B and Cmd+P stay with the browser/OS.
          </p>
          <p class="mb-3 text-[11px] text-base-content/60">
            No need to memorize these — a paired agent can handle most window and pane chores in
            plain English ("split this side by side", "rename this window"). See the <em>Agents</em>
            tab.
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
            <.cheat_row keys="0–9" desc="jump to window 0–9" />
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
            <.cheat_row keys="Ctrl+P" desc="open the command palette (not Cmd+P)" />
            <.cheat_row keys="Ctrl+Space" desc="open the command palette" />
            <.cheat_row keys="Ctrl/Cmd+Shift+F" desc="hide the header for more terminal space" />
            <.cheat_row keys="Ctrl+← → ↑ ↓" desc="move focus to the pane in that direction" />
            <.cheat_row keys="Space" desc="focus the terminal (when nothing interactive is focused)" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">
              Inside the command palette
            </div>
            <.cheat_row keys="Tab" desc="switch category (Files, Commands, Terminal, …)" />
            <.cheat_row keys="Shift+Tab" desc="previous category" />
            <.cheat_row keys="↑ ↓ Enter" desc="browse results and run the one you want" />
            <.cheat_row keys="Esc" desc="close the palette" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">On touch</div>
            <.cheat_row keys="swipe ← →" desc="previous or next window" />
            <.cheat_row keys="two-finger tap" desc="show or hide the soft keyboard" />
            <.cheat_row keys="on-screen C-b" desc="arm leader mode, then type the second key" />
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
            right inside Casein: click, type, navigate, screenshot.
          </p>
          <div class="grid grid-cols-[7rem_1fr] gap-x-3 gap-y-2">
            <.tip_row term="Open one">
              Palette → search <em>Preview: Open …</em>
              for a discovered surface (manager app, Tidewave, or a localhost port),
              or run <code class="rounded bg-base-200 px-1 py-0.5">casein-preview :4000</code>
              in a terminal.
            </.tip_row>
            <.tip_row term="Localhost only">
              Previews load only your workspace's loopback ports. The port must be a common
              dev port, set in workspace metadata, or seen in your terminal output.
            </.tip_row>
            <.tip_row term="Framed apps">
              Apps that block embedding fall back to a built-in proxy automatically.
              Live-reload over WebSocket (HMR) through the proxy is off by default
              (<code class="rounded bg-base-200 px-1 py-0.5">:preview_proxy_hmr</code>).
            </.tip_row>
            <.tip_row term="Stay logged in">
              Previews start fresh each session, so logins reset. Keep auth across restarts with
              <code class="rounded bg-base-200 px-1 py-0.5">
                DEVIDE_PREVIEW_STORAGE_PROFILE=workspace
              </code>
              (or <code class="rounded bg-base-200 px-1 py-0.5">profile</code>
              plus <code class="rounded bg-base-200 px-1 py-0.5">DEVIDE_PREVIEW_STORAGE_PROFILE_NAME</code>).
            </.tip_row>
            <.tip_row term="Responsive">
              <code class="rounded bg-base-200 px-1 py-0.5">casein-preview :4000 --viewport 375x812</code>
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
            Casein wires external coding agents into your workspace over MCP, giving them
            narrow, audited access to your tmux panes and previews. Pair one with <em>Agents tab → Apply Agent Pair layout</em>, then drive the
            <strong>agent</strong>
            pane (not the operator pane). Watch live tool calls under <em>Agents → Live MCP activity</em>.
          </p>
          <div class="grid grid-cols-[5rem_1fr] gap-x-3 gap-y-2">
            <.tip_row term="Claude">
              A bare <code class="rounded bg-base-200 px-1 py-0.5">claude</code>
              in a paired pane auto-loads Casein's terminal + preview MCP servers. It reads
              <code class="rounded bg-base-200 px-1 py-0.5">AGENTS.md</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">CLAUDE.md</code>
              first — keep your workspace notes and the push/deploy rules there. Strongest on
              long, multi-step changes and large context.
            </.tip_row>
            <.tip_row term="Grok">
              A bare <code class="rounded bg-base-200 px-1 py-0.5">grok</code>
              (or <code class="rounded bg-base-200 px-1 py-0.5">
                bash scripts/launch-casein-agent.sh grok
              </code>)
              picks up the project <code class="rounded bg-base-200 px-1 py-0.5">.mcp.json</code>
              Casein materializes. If tools are missing, refresh pairing and relaunch from the
              checkout so project MCP is rewritten — not global <code class="rounded bg-base-200 px-1 py-0.5">~/.grok/config.toml</code>.
            </.tip_row>
            <.tip_row term="Codex">
              Codex gets Casein MCP through launch-time flags, not a project file — start
              <code class="rounded bg-base-200 px-1 py-0.5">codex</code>
              from the paired pane (or <code class="rounded bg-base-200 px-1 py-0.5">
                bash scripts/launch-casein-agent.sh codex
              </code>)
              so the args apply, then confirm it lists the
              <code class="rounded bg-base-200 px-1 py-0.5">terminal</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">preview</code>
              servers before sending commands.
            </.tip_row>
            <.tip_row term="OpenCode">
              Launch with
              <code class="rounded bg-base-200 px-1 py-0.5">
                bash scripts/launch-casein-agent.sh opencode
              </code>
              so Casein injects project <code class="rounded bg-base-200 px-1 py-0.5">.opencode/opencode.json</code>.
              A bare start outside that path may miss workspace MCP.
            </.tip_row>
            <.tip_row term="Sign in">
              By default, agents use the host's global Claude/Codex login. For an
              owner-isolated login instead, sign in once with
              <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth signin codex</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth signin claude</code>.
              Casein detects the owner from the current workspace; once signed in,
              matching workspaces share that owner login automatically. Use
              <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth status</code>
              to check sign-in state.
            </.tip_row>
            <.tip_row term="Pairing">
              Source <code class="rounded bg-base-200 px-1 py-0.5">.devbox-agent.env</code>
              first, and use
              <code class="rounded bg-base-200 px-1 py-0.5">.devbox-agent-prompt.txt</code>
              as a starter prompt. Drive an agent's pane with MCP
              <code class="rounded bg-base-200 px-1 py-0.5">terminal_send_command</code>
              / <code class="rounded bg-base-200 px-1 py-0.5">terminal_send_keys</code>
              — always target the agent pane from topology, never the focused operator pane.
            </.tip_row>
            <.tip_row term="Tmux chores">
              Agents can manage windows and panes for you — ask in plain English to split,
              focus, rename, or rebalance layouts via terminal MCP. That covers most
              day-to-day chores; it is not a 1:1 map of every UI leader key (for example
              copy-link and detach still live in the cockpit).
            </.tip_row>
            <.tip_row term="Artifacts">
              Agents can also publish HTML/static artifact projects over Artifact MCP
              (create, serve, snapshot) — useful for UI walk reports and shareable previews.
            </.tip_row>
          </div>

          <div class="mt-4 border-t border-base-300 pt-3">
            <h3 class="mb-1 text-[11px] font-semibold uppercase tracking-wide text-base-content/60">
              Connect an external agent
            </h3>
            <p class="mb-2 text-[11px] text-base-content/60">
              Mint a <strong>revocable</strong>, auto-expiring MCP bearer for an off-box agent and
              copy a ready-to-paste <code class="rounded bg-base-200 px-1">.mcp.json</code>. It is
              stored hashed and is <strong>not</strong>
              the root token. Scope a call with <code class="rounded bg-base-200 px-1">workspace_id</code>, or omit it to traverse. Full
              walkthrough in <code>docs/external-agent-connect.md</code>.
            </p>

            <div
              :if={@connect_error}
              class="mb-2 rounded border border-error/40 bg-error/10 px-2 py-1 text-[11px] text-error"
            >
              {@connect_error}
            </div>
            <div
              :if={@connect_info}
              class="mb-2 rounded border border-emerald-400/40 bg-emerald-400/10 px-2 py-1 text-[11px] text-emerald-600 dark:text-emerald-300"
            >
              {@connect_info}
            </div>

            <form phx-submit="connect:mint" class="flex items-end gap-2">
              <label class="flex-1">
                <span class="block text-[10px] font-medium uppercase tracking-wide text-base-content/50">
                  Label (optional)
                </span>
                <input
                  type="text"
                  name="label"
                  placeholder="my laptop"
                  maxlength="120"
                  class="mt-1 w-full rounded border border-base-300 bg-base-100 px-2 py-1 text-xs text-base-content outline-none focus:border-primary focus:ring-1 focus:ring-primary"
                />
              </label>
              <button
                type="submit"
                class="rounded bg-primary px-3 py-1.5 text-xs font-medium text-primary-content transition hover:opacity-90"
              >
                Mint token
              </button>
            </form>

            <div
              :if={@connect_new_token}
              class="mt-2 space-y-2 rounded border border-emerald-400/40 bg-emerald-400/10 p-2"
            >
              <p class="text-[11px] font-medium text-emerald-700 dark:text-emerald-300">
                Copy this now — the raw token is shown only once.
              </p>
              <div class="flex flex-wrap gap-2">
                <button
                  type="button"
                  id="help-connect-copy-token"
                  phx-hook="CopyText"
                  data-copy-text={@connect_new_token}
                  class="inline-flex items-center gap-1 rounded border border-base-300 px-2 py-1 text-[11px] font-medium hover:bg-base-200 data-[copied]:border-emerald-400 data-[copied]:text-emerald-600"
                >
                  <.icon name="hero-clipboard" class="size-3.5" /> Copy token
                </button>
                <button
                  type="button"
                  id="help-connect-copy-config"
                  phx-hook="CopyText"
                  data-copy-text={@connect_mcp_json}
                  class="inline-flex items-center gap-1 rounded border border-base-300 px-2 py-1 text-[11px] font-medium hover:bg-base-200 data-[copied]:border-emerald-400 data-[copied]:text-emerald-600"
                >
                  <.icon name="hero-clipboard-document" class="size-3.5" /> Copy .mcp.json
                </button>
              </div>
              <pre class="max-h-44 overflow-auto rounded border border-base-300 bg-base-300/40 p-2 font-mono text-[10px] leading-relaxed"><code>{@connect_mcp_json}</code></pre>
            </div>

            <div class="mt-3">
              <h4 class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-base-content/50">
                Your tokens
              </h4>
              <div
                :if={@connect_tokens == []}
                class="rounded border border-base-300 bg-base-100 p-2 text-[11px] text-base-content/50"
              >
                No active tokens.
              </div>
              <ul :if={@connect_tokens != []} class="space-y-1.5">
                <li
                  :for={token <- @connect_tokens}
                  id={"help-connect-token-#{token.id}"}
                  class="flex items-center justify-between gap-2 rounded border border-base-300 bg-base-100 p-2"
                >
                  <div class="min-w-0">
                    <p class="truncate text-[11px] font-medium text-base-content/80">
                      {token.label || "unlabeled"}
                    </p>
                    <p class="font-mono text-[10px] text-base-content/50">
                      seen {time_label(token.last_seen_at)} · expires {time_label(token.expires_at)}
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="connect:revoke"
                    phx-value-id={token.id}
                    data-confirm="Revoke this token? Any agent using it loses access immediately."
                    class="shrink-0 rounded border border-error/40 px-2 py-1 text-[11px] font-medium text-error hover:bg-error/10"
                  >
                    Revoke
                  </button>
                </li>
              </ul>
            </div>
          </div>

          <p class="mt-3 text-[10px] text-base-content/50">
            More detail in <code>docs/subsystems/agents.md</code>
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Tab clicks are client-side, except Agents: it hosts the connect-agent panel,
  # whose token list is server state, so selecting it also pushes connect:load to
  # refresh tokens (mint/revoke already reload).
  defp cheat_tab_js("agents"), do: JS.push(switch_cheat_tab("agents"), "connect:load")
  defp cheat_tab_js(id), do: switch_cheat_tab(id)

  defp time_label(nil), do: "never"

  defp time_label(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp time_label(_), do: "unknown"

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
