defmodule DevIdeWeb.TerminalSurface do
  @moduledoc """
  Reusable terminal cockpit chrome.

  DevIDE owns pane state, policy, and events. This module owns the visual shell
  around Ghostty terminals: focus wrapper, split handles, loading/error states,
  and the recursive split layout render.
  """
  use DevIdeWeb, :html

  alias DevIdeWeb.TerminalSurface.Pane
  alias DevIdeWeb.WorkspaceLive.PaneLayout

  attr :layout, :any, required: true
  attr :panes, :map, required: true
  attr :focused_pane_id, :string, required: true
  attr :host_id, :string, required: true
  attr :workspace_id, :string, required: true
  attr :equalize_flash, :any, default: nil

  def pane_layout(assigns) do
    ~H"""
    {render_layout_node(assigns, @layout)}
    """
  end

  defp render_layout_node(assigns, {:pane, pane_id}) do
    assigns =
      assigns
      |> Phoenix.Component.assign(:pane_id, pane_id)
      |> Phoenix.Component.assign(:pane, Map.get(assigns.panes, pane_id, %Pane{}))

    ~H"""
    <div
      id={"pane-wrapper-" <> @pane_id}
      class={[
        "group relative min-h-0 flex-1 rounded bg-black p-1",
        if(@pane_id == @focused_pane_id, do: "ring-1 ring-primary", else: "opacity-90")
      ]}
      phx-hook="PaneFocusOnClick"
      phx-click="focus_pane"
      phx-value-pane-id={@pane_id}
      data-pane-id={@pane_id}
      data-host-id={@host_id}
      data-workspace-id={@workspace_id}
      data-session-sid={@pane.session_sid}
    >
      <%= cond do %>
        <% is_pid(@pane.term) -> %>
          <.live_component
            module={DevIdeWeb.GhosttyTerminalComponent}
            id={"ghostty-" <> @pane_id}
            term={@pane.term}
            pty={@pane.pty}
            fit={true}
            autofocus={@pane_id == @focused_pane_id}
            class="h-full w-full font-mono text-sm text-zinc-100"
          />
        <% @pane.error -> %>
          <div
            class="flex h-full w-full flex-col items-center justify-center text-center text-xs text-red-400 p-2"
            role="alert"
            aria-live="polite"
            aria-atomic="true"
          >
            <.icon name="hero-exclamation-triangle" class="size-5 mb-1 text-red-500" />
            <div class="font-semibold">{error_heading(@pane.error)}</div>
            <pre class="mt-1 max-w-[90%] max-h-24 overflow-x-auto whitespace-pre-wrap break-all text-[10px] text-red-400/80 font-mono">{error_detail(@pane.error)}</pre>
            <button
              type="button"
              phx-click="retry_pane"
              phx-value-pane-id={@pane_id}
              aria-label={"Retry terminal for pane " <> @pane_id}
              class="mt-2 rounded border border-red-500/30 bg-red-500/10 px-2 py-0.5 text-[10px] text-red-300 hover:bg-red-500/20 active:bg-red-500/30 transition-colors"
            >
              Retry
            </button>
          </div>
        <% true -> %>
          <div class="flex h-full w-full items-center justify-center text-xs text-zinc-500">
            starting terminal…
          </div>
      <% end %>
    </div>
    """
  end

  defp render_layout_node(assigns, {:split, direction, children, sizes}) do
    flex_class = if direction == :horizontal, do: "flex-row", else: "flex-col"

    sized_children =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child, i} ->
        ratio = Enum.at(sizes, i, 1.0 / max(length(children), 1))
        {child, ratio}
      end)

    assigns =
      assigns
      |> Phoenix.Component.assign(:flex_class, flex_class)
      |> Phoenix.Component.assign(:sized_children, sized_children)
      |> Phoenix.Component.assign(:direction, direction)

    ~H"""
    <div class={[
      "flex min-h-0 flex-1 gap-1 overflow-hidden transition-all duration-150",
      @flex_class,
      if(@equalize_flash,
        do: "ring-1 ring-emerald-400/60 shadow-[0_0_0_1px_#10b98130]",
        else: ""
      )
    ]}>
      <%= for {{child, ratio}, idx} <- Enum.with_index(@sized_children) do %>
        <div
          style={"flex: 0 0 #{:erlang.float_to_binary(ratio * 100, decimals: 2)}%;"}
          class="min-w-0 min-h-0 overflow-hidden flex flex-col h-full w-full"
        >
          {render_layout_node(assigns, child)}
        </div>

        <%= if idx < length(@sized_children) - 1 do %>
          <div
            id={"split-resizer-" <> PaneLayout.first_pane_id(child) <> "-" <> PaneLayout.first_pane_id(Enum.at(@sized_children, idx + 1) |> elem(0))}
            phx-hook="SplitResizer"
            data-direction={if @direction == :horizontal, do: "horizontal", else: "vertical"}
            data-left={PaneLayout.first_pane_id(child)}
            data-right={PaneLayout.first_pane_id(Enum.at(@sized_children, idx + 1) |> elem(0))}
            class={[
              "group flex-none bg-transparent transition-colors z-10 outline-none",
              "hover:bg-emerald-400/10 active:bg-emerald-400/20 focus:bg-emerald-400/15 focus:ring-1 focus:ring-emerald-300/70",
              if(@direction == :horizontal,
                do: "w-3 cursor-col-resize",
                else: "h-3 cursor-row-resize"
              )
            ]}
            tabindex="0"
            role="separator"
            aria-orientation={if @direction == :horizontal, do: "vertical", else: "horizontal"}
            aria-label="Resize split pane. Double-click to equalize. Arrow keys to nudge."
          >
            <div class="pointer-events-none flex h-full w-full items-center justify-center text-zinc-500 opacity-55 transition-all group-hover:text-emerald-400 group-hover:opacity-95 group-focus:text-emerald-300 group-focus:opacity-100">
              <%= if @direction == :horizontal do %>
                <div class="flex gap-0.5">
                  <div class="h-3 w-px bg-current rounded"></div>
                  <div class="h-3 w-px bg-current rounded"></div>
                </div>
              <% else %>
                <div class="flex flex-col gap-0.5">
                  <div class="h-px w-3 bg-current rounded"></div>
                  <div class="h-px w-3 bg-current rounded"></div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp error_heading({:start_failed, :workspace_image_lacks_tmux}),
    do: "Raw terminal unavailable — this workspace's container image has no tmux"

  defp error_heading({:start_failed, _}), do: "Terminal failed to start"

  defp error_heading({:exit_status, status}) when status in [0, 256],
    do: "Shell exited. Click Retry to start a new session."

  defp error_heading({:exit_status, _status}),
    do: "Terminal process exited. Click Retry to start a new session."

  # Recoverable disconnects: the tmux session is created with `new-session -A`,
  # so it persists across a dropped client/PTY. DevIDE auto-reattaches a few
  # times before surfacing this box; if it's showing, the budget was exhausted,
  # but Retry will reattach to the still-running session (scrollback intact).
  defp error_heading(reason) when reason in [:pty_died, :process_died, :terminal_died],
    do: "Terminal disconnected — your tmux session is still running. Click Retry to reattach."

  # Clean shell exit (e.g. the user ran `exit`, or the login shell exited 0).
  defp error_heading(status) when is_integer(status) and status in [0, 256],
    do: "Shell exited. Click Retry to start a new session."

  defp error_heading(_), do: "Terminal exited"

  defp error_detail({:exit_status, status}) when is_integer(status),
    do: "exit status #{status}"

  defp error_detail(status) when is_integer(status), do: "exit status #{status}"
  defp error_detail(reason), do: inspect(reason)
end
