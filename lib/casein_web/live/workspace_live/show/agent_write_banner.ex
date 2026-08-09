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
      class="flex shrink-0 flex-wrap items-center gap-2 border-b border-status-warning/30 bg-status-warning/[0.09] px-3 py-1.5 text-density-body text-status-warning-fg"
      role="status"
    >
      <span class="relative flex size-2 shrink-0">
        <span class="absolute inline-flex size-full animate-ping rounded-full bg-status-warning opacity-40"></span>
        <span class="relative inline-flex size-2 rounded-full bg-status-warning"></span>
      </span>
      <span class="font-semibold">Read-only agents</span>
      <span class="text-status-warning-fg/80">
        Terminal/preview mutations are unavailable until agent write is unlocked.
      </span>
      <form phx-submit="workspace:grant_agent_write_unlock" class="ml-auto flex items-center gap-1.5">
        <input type="hidden" name="minutes" value="30" />
        <button
          type="submit"
          id={"agent-write-locked-banner-unlock-" <> @workspace.id}
          class="rounded border border-status-warning/40 bg-status-warning-soft px-2 py-density-label text-density-label font-semibold text-status-warning-fg hover:bg-status-warning-soft/40 text-status-warning-fg hover:bg-status-warning-soft/50"
        >
          Unlock 30 min
        </button>
      </form>
    </div>
    """
  end
end
