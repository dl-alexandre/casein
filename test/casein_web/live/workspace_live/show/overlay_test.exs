defmodule CaseinWeb.WorkspaceLive.Show.OverlayTest do
  use Casein.TestCase, async: true

  alias CaseinWeb.WorkspaceLive.Show.AgentEvents
  alias CaseinWeb.WorkspaceLive.Show.ClipboardDrawerEvents
  alias CaseinWeb.WorkspaceLive.Show.LeaderHelpEvents
  alias CaseinWeb.WorkspaceLive.Show.Overlay

  # Every floating surface open at once — the state the arbiter exists to make
  # unreachable.
  @all_open %{
    palette_open: true,
    context_menu: %{menu: "pane", items: []},
    audit_drawer_open: true,
    notif_drawer_open: true,
    clipboard_drawer_open: true,
    template_library_open: true,
    template_preview: %{template: %{id: "t1"}},
    leader_help_open: true
  }

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      endpoint: CaseinWeb.Endpoint,
      view: CaseinWeb.WorkspaceLive.Show,
      root_pid: self(),
      private: %{live_temp: %{}},
      assigns: Map.merge(%{__changed__: %{}}, assigns)
    }
  end

  defp open_overlays(socket) do
    Enum.filter(Overlay.overlays(), fn overlay ->
      case overlay do
        :palette -> socket.assigns.palette_open
        :context_menu -> not is_nil(socket.assigns.context_menu)
        :audit_drawer -> socket.assigns.audit_drawer_open
        :notifications -> socket.assigns.notif_drawer_open
        :clipboard_drawer -> socket.assigns.clipboard_drawer_open
        :template_library -> socket.assigns.template_library_open
        :template_preview -> not is_nil(socket.assigns.template_preview)
        :leader_help -> socket.assigns.leader_help_open
      end
    end)
  end

  describe "close_others/2" do
    for overlay <- [
          :palette,
          :context_menu,
          :audit_drawer,
          :notifications,
          :clipboard_drawer,
          :template_library,
          :template_preview,
          :leader_help
        ] do
      test "keeping #{overlay} closes every other surface" do
        socket = Overlay.close_others(socket(@all_open), unquote(overlay))

        assert open_overlays(socket) == [unquote(overlay)]
      end
    end

    test "leaves the kept surface's own assign untouched" do
      socket = Overlay.close_others(socket(@all_open), :template_preview)

      assert socket.assigns.template_preview == %{template: %{id: "t1"}}
    end
  end

  describe "close_all/1" do
    test "closes every floating surface" do
      assert socket(@all_open) |> Overlay.close_all() |> open_overlays() == []
    end
  end

  describe "assign presence guard" do
    test "does not invent assigns the socket never carried" do
      # The notifications drawer mounts from its own module and is reusable
      # outside the cockpit, so a socket may carry only a subset of these keys.
      socket = Overlay.close_all(socket(%{palette_open: true}))

      assert Map.keys(socket.assigns) |> Enum.sort() == [:__changed__, :palette_open]
      refute socket.assigns.palette_open
    end
  end

  describe "structural coverage" do
    test "every declared overlay is closable" do
      # Guards against adding an overlay to the type without a reset entry,
      # which would silently exempt it from the one-at-a-time rule.
      for overlay <- Overlay.overlays() do
        assert socket(@all_open) |> Overlay.close(overlay) |> open_overlays() ==
                 Overlay.overlays() -- [overlay]
      end
    end
  end

  describe "open transitions route through the arbiter" do
    test "opening the audit drawer closes the palette" do
      {:noreply, socket} =
        AgentEvents.handle_event(
          "audit_drawer:toggle",
          %{},
          socket(%{@all_open | audit_drawer_open: false})
        )

      assert open_overlays(socket) == [:audit_drawer]
    end

    test "closing the audit drawer leaves other surfaces alone" do
      # Toggling *closed* is not an open transition — it must not reach in and
      # clear unrelated state.
      {:noreply, socket} = AgentEvents.handle_event("audit_drawer:toggle", %{}, socket(@all_open))

      refute socket.assigns.audit_drawer_open
      assert socket.assigns.palette_open
    end

    test "opening the clipboard drawer closes the palette" do
      {:noreply, socket} =
        ClipboardDrawerEvents.handle_event(
          "clipboard:toggle",
          %{},
          socket(%{@all_open | clipboard_drawer_open: false})
        )

      assert open_overlays(socket) == [:clipboard_drawer]
    end

    test "closing the clipboard drawer leaves other surfaces alone" do
      {:noreply, socket} =
        ClipboardDrawerEvents.handle_event("clipboard:toggle", %{}, socket(@all_open))

      refute socket.assigns.clipboard_drawer_open
      assert socket.assigns.palette_open
    end

    test "opening the leader cheatsheet closes the palette" do
      {:noreply, socket} =
        LeaderHelpEvents.handle_event(
          "leader_help:toggle",
          %{},
          socket(%{@all_open | leader_help_open: false})
        )

      assert open_overlays(socket) == [:leader_help]
    end

    test "closing the leader cheatsheet leaves other surfaces alone" do
      {:noreply, socket} =
        LeaderHelpEvents.handle_event("leader_help:toggle", %{}, socket(@all_open))

      refute socket.assigns.leader_help_open
      assert socket.assigns.palette_open
    end
  end
end
