defmodule DevIdeWeb.ConnectAgentDrawer do
  @moduledoc """
  "Connect an external agent" drawer: a header trigger + right-side slide-over
  where a logged-in cockpit user mints a self-serve, revocable MCP bearer token
  and copies a ready-to-paste durable `.mcp.json`. State + events live in
  `DevIdeWeb.WorkspaceLive.Show.ConnectEvents`; the token lifecycle is
  `DevIDE.Agents.OrchestratorTokens`. Styled to match `NotificationsDrawer`.
  """

  use DevIdeWeb, :html

  attr :id, :string, default: "connect-agent-button"

  def connect_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="connect:toggle"
      class="relative inline-flex items-center justify-center rounded border border-base-300 p-1 text-sm text-base-content/80 hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:p-0"
      title="Connect an external agent"
      aria-label="Connect an external agent"
    >
      <.icon name="hero-link" class="size-4" />
    </button>
    """
  end

  attr :open, :boolean, required: true
  attr :new_token, :string, default: nil
  attr :mcp_json, :string, default: nil
  attr :tokens, :list, default: []
  attr :error, :string, default: nil
  attr :info, :string, default: nil

  def connect_agent_drawer(assigns) do
    ~H"""
    <div :if={@open} id="connect-agent-drawer" class="fixed inset-0 z-40 pointer-events-none">
      <div class="absolute inset-0 bg-black/20 pointer-events-auto" phx-click="connect:close"></div>
      <aside
        class="absolute right-0 top-0 bottom-0 flex w-[460px] max-w-[94vw] flex-col border-l bg-white pointer-events-auto shadow-xl"
        role="complementary"
        aria-label="Connect an external agent drawer"
      >
        <header class="flex items-center justify-between border-b px-4 py-3">
          <div>
            <h2 class="text-sm font-semibold tracking-tight text-zinc-950">
              Connect an external agent
            </h2>
            <p class="font-mono text-[11px] text-zinc-500">MCP bearer · revocable · expires</p>
          </div>
          <button
            id="connect-drawer-close"
            phx-click="connect:close"
            class="rounded border px-2 py-0.5 text-[11px] hover:bg-zinc-50"
            title="Close"
          >
            ×
          </button>
        </header>

        <div
          :if={@error}
          id="connect-error"
          class="border-b border-red-200 bg-red-50 px-4 py-2 text-xs text-red-700"
        >
          {@error}
        </div>
        <div
          :if={@info}
          id="connect-info"
          class="border-b border-emerald-200 bg-emerald-50 px-4 py-2 text-xs text-emerald-700"
        >
          {@info}
        </div>

        <div class="min-h-0 flex-1 space-y-4 overflow-auto px-4 py-4">
          <section class="space-y-2 text-sm text-zinc-700">
            <p>
              Mint a bearer token and point an off-box agent at DevIDE's MCP. The token is <strong>revocable</strong>, expires automatically, and is stored hashed — it is
              <strong>not</strong>
              the root token. It reaches every workspace; confine a call by
              passing <code class="rounded bg-zinc-100 px-1">workspace_id</code>, omit it to traverse.
            </p>
            <p class="text-xs text-zinc-500">
              The config below uses the public HTTPS endpoint (Door 2). Test it <em>with</em>
              the bearer — an unauthenticated request returns a 302 login redirect by design.
              For an SSH tunnel (Door 1) or the full walkthrough, see <code class="rounded bg-zinc-100 px-1">docs/external-agent-connect.md</code>.
            </p>
          </section>

          <section class="space-y-2">
            <form phx-submit="connect:mint" class="flex items-end gap-2">
              <label class="flex-1">
                <span class="block text-[11px] font-medium uppercase tracking-wide text-zinc-500">
                  Label (optional)
                </span>
                <input
                  type="text"
                  name="label"
                  placeholder="my laptop"
                  maxlength="120"
                  class="mt-1 w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm text-zinc-950"
                />
              </label>
              <button
                id="connect-mint"
                type="submit"
                class="rounded bg-zinc-950 px-3 py-2 text-sm font-medium text-white transition hover:bg-zinc-800"
              >
                Mint token
              </button>
            </form>

            <div
              :if={@new_token}
              id="connect-new-token"
              class="space-y-2 rounded border border-emerald-200 bg-emerald-50/60 p-3"
            >
              <p class="text-xs font-medium text-emerald-800">
                Copy this now — the raw token is shown only once.
              </p>
              <details class="rounded border border-zinc-200 bg-white">
                <summary class="cursor-pointer select-none px-2 py-1 text-[11px] font-semibold uppercase tracking-wide text-zinc-500 hover:bg-zinc-50">
                  Reveal token
                </summary>
                <code class="block break-all border-t border-zinc-200 px-2 py-1.5 font-mono text-[11px] text-zinc-800">
                  {@new_token}
                </code>
              </details>
              <div class="flex flex-wrap gap-2">
                <button
                  id="connect-copy-token"
                  type="button"
                  phx-hook="CopyText"
                  data-copy-text={@new_token}
                  class="inline-flex items-center gap-1 rounded border border-zinc-300 px-2 py-1 text-xs font-medium hover:bg-zinc-50 data-[copied]:border-emerald-400 data-[copied]:text-emerald-700"
                >
                  <.icon name="hero-clipboard" class="size-3.5" /> Copy token
                </button>
                <button
                  id="connect-copy-config"
                  type="button"
                  phx-hook="CopyText"
                  data-copy-text={@mcp_json}
                  class="inline-flex items-center gap-1 rounded border border-zinc-300 px-2 py-1 text-xs font-medium hover:bg-zinc-50 data-[copied]:border-emerald-400 data-[copied]:text-emerald-700"
                >
                  <.icon name="hero-clipboard-document" class="size-3.5" /> Copy .mcp.json
                </button>
              </div>
              <pre class="max-h-52 overflow-auto rounded border border-zinc-200 bg-zinc-950 p-2 font-mono text-[10px] leading-relaxed text-zinc-100"><code>{@mcp_json}</code></pre>
            </div>
          </section>

          <section class="space-y-2">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Your tokens</h3>
            <div
              :if={@tokens == []}
              id="connect-tokens-empty"
              class="rounded border border-zinc-200 bg-white p-3 text-sm text-zinc-500"
            >
              No active tokens.
            </div>
            <ul :if={@tokens != []} class="space-y-2">
              <li
                :for={token <- @tokens}
                id={"connect-token-#{token.id}"}
                class="flex items-center justify-between gap-2 rounded border border-zinc-200 bg-white p-2.5"
              >
                <div class="min-w-0">
                  <p class="truncate text-sm font-medium text-zinc-800">
                    {token.label || "unlabeled"}
                  </p>
                  <p class="font-mono text-[10px] text-zinc-500">
                    seen {time_label(token.last_seen_at)} · expires {time_label(token.expires_at)}
                  </p>
                </div>
                <button
                  id={"connect-revoke-#{token.id}"}
                  type="button"
                  phx-click="connect:revoke"
                  phx-value-id={token.id}
                  data-confirm="Revoke this token? Any agent using it loses access immediately."
                  class="shrink-0 rounded border border-red-200 px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50"
                >
                  Revoke
                </button>
              </li>
            </ul>
          </section>
        </div>
      </aside>
    </div>
    """
  end

  defp time_label(nil), do: "never"

  defp time_label(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
