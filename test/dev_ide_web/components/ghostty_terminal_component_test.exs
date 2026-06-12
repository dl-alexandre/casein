defmodule DevIdeWeb.GhosttyTerminalComponentTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.GhosttyTerminalComponent

  setup do
    {:ok, term} = start_supervised({Ghostty.Terminal, cols: 40, rows: 6, max_scrollback: 200})
    %{term: term}
  end

  test "Ghostty.Terminal.scroll moves viewport through scrollback", %{term: term} do
    lines = Enum.map_join(1..40, "\n", &"scroll-line-#{&1}")
    :ok = Ghostty.Terminal.write(term, lines <> "\n")

    %{total: total, len: len, offset: before} = Ghostty.Terminal.scrollbar(term)
    assert total > len

    :ok = Ghostty.Terminal.scroll(term, -3)
    %{offset: after_up} = Ghostty.Terminal.scrollbar(term)
    assert after_up < before

    :ok = Ghostty.Terminal.scroll(term, 3)
    %{offset: after_down} = Ghostty.Terminal.scrollbar(term)
    assert after_down > after_up
  end

  test "scroll handle_event repaints after moving the viewport", %{term: term} do
    lines = Enum.map_join(1..30, "\n", &"pane-line-#{&1}")
    :ok = Ghostty.Terminal.write(term, lines <> "\n")

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(%{})
      |> Map.put(:endpoint, DevIdeWeb.Endpoint)

    {:ok, socket} =
      GhosttyTerminalComponent.update(
        %{id: "ghostty-pane-1", term: term, pty: nil, fit: false, autofocus: false, class: ""},
        socket
      )

    {:noreply, socket} = GhosttyTerminalComponent.handle_event("scroll", %{"delta" => -2}, socket)
    assert socket.assigns.last_render_cells != nil
  end
end
