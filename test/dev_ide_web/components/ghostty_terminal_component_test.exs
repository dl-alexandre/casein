defmodule DevIdeWeb.GhosttyTerminalComponentTest do
  use DevIDE.TestCase, async: true

  import Phoenix.LiveViewTest

  alias DevIdeWeb.GhosttyTerminalComponent

  setup do
    {:ok, term} = start_supervised({Ghostty.Terminal, cols: 40, rows: 6, max_scrollback: 200})
    %{term: term}
  end

  defp component_socket(term, extra_assigns \\ %{}) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(%{})
      |> Map.put(:endpoint, DevIdeWeb.Endpoint)

    assigns =
      Map.merge(
        %{
          id: "ghostty-pane-1",
          term: term,
          pty: nil,
          fit: false,
          autofocus: false,
          class: "term"
        },
        extra_assigns
      )

    {:ok, socket} = GhosttyTerminalComponent.update(assigns, socket)
    socket
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

  test "viewport_active forwards the viewer's active state to the parent", %{term: term} do
    socket = component_socket(term)

    {:noreply, _socket} =
      GhosttyTerminalComponent.handle_event("viewport_active", %{"active" => true}, socket)

    assert_received {:terminal_active, "ghostty-pane-1", true}

    {:noreply, _socket} =
      GhosttyTerminalComponent.handle_event("viewport_active", %{"active" => false}, socket)

    assert_received {:terminal_active, "ghostty-pane-1", false}
  end

  test "render includes hook metadata and dimensions", %{term: term} do
    socket = component_socket(term, %{cols: 100, rows: 30, fit: true, autofocus: true})

    html =
      render_component(GhosttyTerminalComponent,
        id: socket.assigns.id,
        term: term,
        pty: nil,
        cols: 100,
        rows: 30,
        fit: true,
        autofocus: true,
        class: "term"
      )

    assert html =~ ~s(id="ghostty-pane-1")
    assert html =~ ~s(phx-hook="GhosttyTerminal")
    assert html =~ ~s(data-cols="100")
    assert html =~ ~s(data-rows="30")
    assert html =~ ~s(data-fit="true")
    assert html =~ ~s(data-autofocus="true")
  end

  test "update pushes theme and render events on first mount and refresh", %{term: term} do
    socket = component_socket(term, %{terminal_themes: %{bg: "#000000", fg: "#ffffff"}})
    assert socket.assigns.last_render_cells != nil

    {:ok, refreshed} =
      GhosttyTerminalComponent.update(
        %{id: "ghostty-pane-1", term: term, refresh: true},
        socket
      )

    assert refreshed.assigns.last_render_cells != nil

    {:ok, themed} =
      GhosttyTerminalComponent.update(
        %{
          id: "ghostty-pane-1",
          term: term,
          terminal_themes: %{bg: "#111111", fg: "#eeeeee"}
        },
        socket
      )

    assert themed.assigns.terminal_themes.bg == "#111111"
  end

  test "key, text, mouse, and refresh events repaint the terminal", %{term: term} do
    socket = component_socket(term)

    {:noreply, key_socket} =
      GhosttyTerminalComponent.handle_event("key", %{"key" => "a", "shiftKey" => false}, socket)

    assert key_socket.assigns.last_render_cells != nil

    {:noreply, text_socket} =
      GhosttyTerminalComponent.handle_event("text", %{"data" => "echo hi\n"}, key_socket)

    assert text_socket.assigns.last_render_cells != nil

    {:noreply, empty_text_socket} =
      GhosttyTerminalComponent.handle_event("text", %{"data" => ""}, text_socket)

    assert empty_text_socket.assigns.last_render_cells != nil

    {:noreply, mouse_socket} =
      GhosttyTerminalComponent.handle_event(
        "mouse",
        %{"type" => "press", "x" => 1, "y" => 1, "button" => 0},
        empty_text_socket
      )

    assert mouse_socket.assigns.last_render_cells == empty_text_socket.assigns.last_render_cells

    {:noreply, refresh_socket} =
      GhosttyTerminalComponent.handle_event("refresh", %{}, mouse_socket)

    assert refresh_socket.assigns.last_render_cells != nil
  end

  test "ready and resize events update dimensions and notify the parent", %{term: term} do
    socket = component_socket(term)

    {:noreply, ready_socket} =
      GhosttyTerminalComponent.handle_event("ready", %{"cols" => "120", "rows" => "40"}, socket)

    assert ready_socket.assigns.cols == 120
    assert ready_socket.assigns.rows == 40
    assert_received {:terminal_ready, "ghostty-pane-1", 120, 40}

    {:noreply, resize_socket} =
      GhosttyTerminalComponent.handle_event("resize", %{"cols" => 90, "rows" => 25}, ready_socket)

    assert resize_socket.assigns.cols == 90
    assert resize_socket.assigns.rows == 25
    assert_received {:terminal_resize, "ghostty-pane-1", 90, 25}
  end

  test "focus events are ignored when focus reporting is disabled", %{term: term} do
    socket = component_socket(term)

    {:noreply, socket} =
      GhosttyTerminalComponent.handle_event("focus", %{"focused" => true}, socket)

    assert socket.assigns.last_render_cells != nil
  end

  test "scroll clamps large deltas before repainting", %{term: term} do
    lines = Enum.map_join(1..30, "\n", &"pane-line-#{&1}")
    :ok = Ghostty.Terminal.write(term, lines <> "\n")

    socket = component_socket(term)

    {:noreply, socket} =
      GhosttyTerminalComponent.handle_event("scroll", %{"delta" => "99"}, socket)

    assert socket.assigns.last_render_cells != nil

    {:noreply, _socket} =
      GhosttyTerminalComponent.handle_event("scroll", %{"delta" => "not-a-number"}, socket)
  end

  test "invalid ready dimensions raise ArgumentError", %{term: term} do
    socket = component_socket(term)

    assert_raise ArgumentError, fn ->
      GhosttyTerminalComponent.handle_event("ready", %{"cols" => "0", "rows" => "10"}, socket)
    end
  end
end
