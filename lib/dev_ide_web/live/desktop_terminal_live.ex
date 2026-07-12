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
    <Layouts.app flash={@flash} current_scope={@current_scope} full_bleed={true}>
      <section id="desktop-terminal-page" class="flex min-h-0 flex-1 flex-col bg-slate-950">
        <div class="flex items-center justify-between border-b border-white/10 bg-slate-900 px-4 py-2">
          <div class="flex items-center gap-3">
            <span class="flex size-7 items-center justify-center rounded-md bg-sky-400/10 text-sky-300">
              <.icon name="hero-command-line" class="size-4" />
            </span>
            <div>
              <h1 class="text-sm font-semibold text-slate-100">PowerShell</h1>
              <p class="text-xs text-slate-400">Native Windows session · browser reconnect safe</p>
            </div>
          </div>
          <span id="desktop-terminal-status" class="flex items-center gap-2 text-xs text-slate-400">
            <span class={[
              "size-2 rounded-full",
              @terminal_status == :running && "bg-emerald-400 shadow-[0_0_8px_rgba(52,211,153,0.7)]",
              @terminal_status != :running && "bg-amber-400"
            ]}></span>
            {status_label(@terminal_status)}
          </span>
        </div>

        <div class="relative min-h-0 flex-1 p-3">
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
              class="overflow-hidden rounded-lg border border-white/10 bg-[#0b1020] shadow-2xl"
            />
          <% else %>
            <div
              id="desktop-terminal-loading"
              class="grid h-full place-items-center text-sm text-slate-400"
            >
              Starting native PowerShell…
            </div>
          <% end %>
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
