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
  attr :pane_count, :integer, required: true
  attr :zoomed_pane_id, :string, default: nil
  attr :host_id, :string, required: true
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
    >
      <%= if @pane_id == @focused_pane_id do %>
        <div class="absolute right-1 top-1 z-10 flex gap-0.5 rounded border border-zinc-700 bg-zinc-900/80 p-0.5 text-xs backdrop-blur">
          <button
            type="button"
            phx-click="split_right"
            class="rounded px-1.5 py-0.5 font-mono text-zinc-200 hover:bg-emerald-500/20 hover:text-emerald-300"
            title="Split right"
            aria-label="Split right"
          >
            ⇥
          </button>
          <button
            type="button"
            phx-click="split_down"
            class="rounded px-1.5 py-0.5 font-mono text-zinc-200 hover:bg-emerald-500/20 hover:text-emerald-300"
            title="Split down"
            aria-label="Split down"
          >
            ⤓
          </button>
          <%= if @pane_count > 1 or @zoomed_pane_id do %>
            <button
              type="button"
              phx-click="zoom_pane"
              phx-value-pane-id={@pane_id}
              class="rounded px-1.5 py-0.5 font-mono text-zinc-200 hover:bg-emerald-500/20 hover:text-emerald-300"
              title={
                if @zoomed_pane_id == @pane_id,
                  do: "Restore split (double-tap)",
                  else: "Zoom pane (double-tap)"
              }
              aria-label={if @zoomed_pane_id == @pane_id, do: "Restore split", else: "Zoom pane"}
            >
              {if @zoomed_pane_id == @pane_id, do: "▣", else: "▢"}
            </button>
          <% end %>
          <button
            type="button"
            phx-click="close_pane"
            phx-value-pane-id={@pane_id}
            class={[
              "rounded px-1.5 py-0.5 font-mono transition-colors",
              if(@pane_count <= 1,
                do: "text-red-900/40 cursor-not-allowed",
                else: "text-red-300 hover:bg-red-500/30 hover:text-red-100"
              )
            ]}
            title={if @pane_count <= 1, do: "Cannot close the last pane", else: "Close pane"}
            aria-label="Close pane"
            disabled={@pane_count <= 1}
          >
            ×
          </button>
        </div>
      <% end %>

      <%= cond do %>
        <% is_pid(@pane.term) -> %>
          <.live_component
            module={Ghostty.LiveTerminal.Component}
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
            <pre class="mt-1 max-w-[90%] max-h-24 overflow-x-auto whitespace-pre-wrap break-all text-[10px] text-red-400/80 font-mono">{inspect(@pane.error)}</pre>
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

  defp error_heading({:start_failed, _}), do: "Terminal failed to start"
  defp error_heading(_), do: "Terminal exited"
end
