defmodule CaseinWeb.WorkspaceLive.Show.AgentWriteBanner do
  @moduledoc false

  use CaseinWeb, :html

  @doc "Chrome banner when agent-write unlock is inactive (Casein #592)."
  attr :workspace, :map, required: true
  attr :agent_write_unlock, :map, required: true

  def agent_write_locked_banner(assigns) do
    ~H"""
    <div
      :if={@agent_write_unlock.status != :active}
      id={"agent-write-locked-banner-" <> @workspace.id}
      class="flex shrink-0 flex-wrap items-center gap-2 border-b border-amber-400/30 bg-amber-400/[0.09] px-3 py-1.5 text-[11px] text-amber-900 dark:text-amber-100"
      role="status"
    >
      <span class="relative flex size-2 shrink-0">
        <span class="absolute inline-flex size-full animate-ping rounded-full bg-amber-400 opacity-40"></span>
        <span class="relative inline-flex size-2 rounded-full bg-amber-500"></span>
      </span>
      <span class="font-semibold">Read-only agents</span>
      <span class="text-amber-800/80 dark:text-amber-100/70">
        Terminal/preview mutations are unavailable until agent write is unlocked.
      </span>
      <form phx-submit="workspace:grant_agent_write_unlock" class="ml-auto flex items-center gap-1.5">
        <input type="hidden" name="minutes" value="30" />
        <button
          type="submit"
          id={"agent-write-locked-banner-unlock-" <> @workspace.id}
          class="rounded border border-amber-700/40 bg-amber-50 px-2 py-0.5 text-[10px] font-semibold text-amber-900 hover:bg-amber-100 dark:bg-amber-950/40 dark:text-amber-100 dark:hover:bg-amber-900/50"
        >
          Unlock 30 min
        </button>
      </form>
    </div>
    """
  end
end
