defmodule DevIdeWeb.DesktopTerminalLive do
  @moduledoc "Native desktop PowerShell terminal."

  use DevIdeWeb, :live_view

  alias DevIDE.Desktop.PowerShellSession

  @terminal_id "desktop-powershell-terminal"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign_new(:current_scope, fn -> nil end)
      |> assign(:page_title, "PowerShell")
      |> assign(:term, nil)
      |> assign(:pty, nil)
      |> assign(:terminal_id, @terminal_id)
      |> assign(:terminal_status, :connecting)
      |> assign(:refresh, 0)
      |> assign(:cols, 100)
      |> assign(:rows, 30)

    if connected?(socket) do
      {:ok, attach_terminal(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:desktop_terminal_output, _data}, socket) do
    {:noreply, update(socket, :refresh, &(&1 + 1))}
  end

  def handle_info({:desktop_terminal_exit, reason}, socket) do
    {:noreply, assign(socket, :terminal_status, {:exited, reason})}
  end

  def handle_info({:terminal_ready, @terminal_id, cols, rows}, socket) do
    {:noreply, assign(socket, cols: cols, rows: rows)}
  end

  def handle_info({:terminal_resize, @terminal_id, cols, rows}, socket) do
    if socket.assigns.pty, do: Ghostty.PTY.resize(socket.assigns.pty, cols, rows)
    {:noreply, assign(socket, cols: cols, rows: rows)}
  end

  def handle_info({:terminal_active, @terminal_id, _active}, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      full_bleed={true}
      navigation={false}
    >
      <section
        id="desktop-terminal-page"
        class="workspace-shell flex min-h-0 flex-1 flex-col overflow-hidden bg-base-100 px-2 pt-1 text-base-content sm:px-4 lg:px-6"
      >
        <header
          id="desktop-cockpit-header"
          class="workspace-main-header mb-1 flex h-10 w-full min-w-0 shrink-0 items-center gap-1 border-b border-base-300/70 px-0.5 pb-0.5 text-xs"
        >
          <div class="flex min-w-0 items-center gap-1.5 pr-2">
            <.link
              navigate={~p"/desktop-terminal"}
              aria-label="DevIDE Windows home"
              class="flex size-7 shrink-0 items-center justify-center rounded-md bg-emerald-500/10 text-emerald-400 transition hover:bg-emerald-500/20"
            >
              <.icon name="hero-command-line" class="size-4" />
            </.link>
            <span class="hidden font-semibold tracking-tight sm:inline">DevIDE</span>
            <span class="rounded border border-base-300 bg-base-200/60 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wider text-base-content/60">
              Windows
            </span>
          </div>

          <div class="flex min-w-0 flex-1 items-end self-stretch">
            <div class="flex h-full min-w-0 items-center gap-2 border-b-2 border-emerald-500 px-3 text-base-content">
              <.icon name="hero-command-line-micro" class="size-3.5 shrink-0 text-base-content/60" />
              <span class="truncate font-medium">PowerShell</span>
              <span class="size-1.5 shrink-0 rounded-full bg-emerald-400 shadow-[0_0_6px_rgba(52,211,153,0.7)]"></span>
            </div>
          </div>

          <div class="flex shrink-0 items-center gap-1 pl-2">
            <span
              id="desktop-terminal-status"
              class="hidden items-center gap-1.5 text-[11px] text-base-content/60 sm:flex"
            >
              <span class={[
                "size-1.5 rounded-full",
                @terminal_status == :running &&
                  "bg-emerald-400 shadow-[0_0_6px_rgba(52,211,153,0.7)]",
                @terminal_status != :running && "bg-amber-400"
              ]}></span>
              {status_label(@terminal_status)}
            </span>
            <button
              type="button"
              title="Notifications are available in the full workspace cockpit"
              aria-label="Notifications"
              class="btn btn-ghost btn-xs btn-square text-base-content/55"
            >
              <.icon name="hero-bell" class="size-3.5" />
            </button>
            <Layouts.theme_toggle />
          </div>
        </header>

        <div class="relative min-h-0 flex-1 pb-2">
          <div
            class="flex h-full min-h-0 flex-col overflow-hidden rounded-md border shadow-[0_12px_40px_rgba(0,0,0,0.22)]"
            style="background: var(--devide-term-bg); border-color: var(--devide-term-border);"
          >
            <div
              class="flex h-7 shrink-0 items-center justify-between border-b px-2.5 text-[10px] uppercase tracking-wider"
              style="border-color: var(--devide-term-border); color: var(--devide-term-muted); background: color-mix(in srgb, var(--devide-term-bg) 92%, var(--devide-term-fg));"
            >
              <span>Local desktop</span>
              <span class="flex items-center gap-1.5 normal-case tracking-normal text-zinc-400">
                <span class="size-1.5 rounded-full bg-emerald-400"></span> PowerShell
              </span>
            </div>

            <div class="relative min-h-0 flex-1">
              <%= if is_pid(@term) do %>
                <.live_component
                  module={DevIdeWeb.GhosttyTerminalComponent}
                  id={@terminal_id}
                  term={@term}
                  pty={@pty}
                  cols={@cols}
                  rows={@rows}
                  fit={true}
                  autofocus={true}
                  refresh={@refresh}
                  class="overflow-hidden [background:var(--devide-term-bg)]"
                />
              <% else %>
                <div
                  id="desktop-terminal-loading"
                  class="grid h-full place-items-center text-sm text-zinc-500"
                >
                  Starting native PowerShell…
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp attach_terminal(socket) do
    with true <- Application.get_env(:dev_ide, :desktop_mode, false),
         :ok <- PowerShellSession.ensure_started(),
         {:ok, term, pty, status} <- PowerShellSession.subscribe() do
      assign(socket, term: term, pty: pty, terminal_status: status)
    else
      false -> assign(socket, :terminal_status, {:error, :desktop_profile_required})
      {:error, reason} -> assign(socket, :terminal_status, {:error, reason})
    end
  end

  defp status_label(:running), do: "Connected"
  defp status_label(:connecting), do: "Starting"
  defp status_label({:exited, _reason}), do: "Exited"
  defp status_label({:error, _reason}), do: "Unavailable"
end
