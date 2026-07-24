defmodule CaseinWeb.WorkspaceLive.Show.PaletteEventsTest do
  use Casein.DataCase, async: true

  alias Casein.CommandPalette.Usage
  alias CaseinWeb.WorkspaceLive.Show.PaletteEvents

  # Covers palette open/query/nav/execute (including the resolve {:ok, _} dispatch
  # path that records frecency via Usage.record/2) plus the search:run no-root
  # guard. Each test uses a unique workspace id so Repo upserts stay isolated.

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      endpoint: CaseinWeb.Endpoint,
      view: CaseinWeb.WorkspaceLive.Show,
      root_pid: self(),
      private: %{live_temp: %{}},
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: "ws-palette-#{System.unique_integer([:positive])}"},
            host_loc: {:error, :not_set},
            host_path: {:error, :not_set},
            flash: %{},
            tab: "terminal",
            palette_open: false,
            palette_query: "",
            palette_items: [],
            palette_selected_idx: 0,
            palette_category: :all,
            palette_usage: %{},
            pane_data: %{},
            terminal_preset_id: "catppuccin",
            terminal_themes: %{preset: "catppuccin"},
            palette_theme_preview_id: nil
          },
          assigns
        )
    }
  end

  defp theme_item(preset) do
    %{
      id: "terminal:theme:" <> preset,
      kind: :action,
      label: "Terminal theme: " <> preset,
      payload: %{event: "terminal:set_preset", params: %{"preset" => preset}}
    }
  end

  describe "search:run" do
    test "assigns no_root error when workspace root is unavailable" do
      {:noreply, socket} =
        PaletteEvents.handle_event("search:run", %{"query" => "hello"}, socket())

      assert socket.assigns.search_state == {:error, :no_root}
    end
  end

  describe "palette:open" do
    test "opens with items, selected index 0, and category from the active tab" do
      {:noreply, socket} =
        PaletteEvents.handle_event("palette:open", %{}, socket(%{tab: "terminal"}))

      assert socket.assigns.palette_open == true
      assert is_list(socket.assigns.palette_items)
      assert socket.assigns.palette_items != []
      assert socket.assigns.palette_selected_idx == 0
      # default_palette_category("terminal") -> :tmux
      assert socket.assigns.palette_category == :tmux
    end
  end

  describe "palette:query" do
    test "re-queries items and resets palette_selected_idx to 0" do
      {:noreply, open} =
        PaletteEvents.handle_event("palette:open", %{}, socket(%{tab: "files"}))

      assert length(open.assigns.palette_items) > 1

      {:noreply, navigated} =
        PaletteEvents.handle_event("palette:nav", %{"dir" => "down"}, open)

      assert navigated.assigns.palette_selected_idx == 1

      {:noreply, socket} =
        PaletteEvents.handle_event("palette:query", %{"query" => "tab"}, navigated)

      assert socket.assigns.palette_query == "tab"
      assert socket.assigns.palette_selected_idx == 0
      assert is_list(socket.assigns.palette_items)
    end
  end

  describe "palette:nav" do
    test "wraps at both ends of the items list" do
      items = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      s = socket(%{palette_items: items, palette_selected_idx: 0})

      {:noreply, s} = PaletteEvents.handle_event("palette:nav", %{"dir" => "up"}, s)
      assert s.assigns.palette_selected_idx == 2

      {:noreply, s} = PaletteEvents.handle_event("palette:nav", %{"dir" => "down"}, s)
      assert s.assigns.palette_selected_idx == 0

      {:noreply, s} = PaletteEvents.handle_event("palette:nav", %{"dir" => "down"}, s)
      assert s.assigns.palette_selected_idx == 1

      {:noreply, s} = PaletteEvents.handle_event("palette:nav", %{"dir" => "down"}, s)
      assert s.assigns.palette_selected_idx == 2

      {:noreply, s} = PaletteEvents.handle_event("palette:nav", %{"dir" => "down"}, s)
      assert s.assigns.palette_selected_idx == 0
    end

    test "live-previews a terminal theme row without committing the preset" do
      items = [%{id: "action:other"}, theme_item("nord"), theme_item("gruvbox")]
      s = socket(%{palette_items: items, palette_selected_idx: 0, palette_open: true})

      {:noreply, s} = PaletteEvents.handle_event("palette:nav", %{"dir" => "down"}, s)

      assert s.assigns.palette_selected_idx == 1
      assert s.assigns.palette_theme_preview_id == "nord"
      assert s.assigns.terminal_preset_id == "catppuccin"
      assert s.assigns.terminal_themes.preset == "nord"
      assert s.assigns.terminal_themes.preview == true

      {:noreply, s} = PaletteEvents.handle_event("palette:nav", %{"dir" => "down"}, s)

      assert s.assigns.palette_theme_preview_id == "gruvbox"
      assert s.assigns.terminal_preset_id == "catppuccin"
      assert s.assigns.terminal_themes.preset == "gruvbox"
    end

    test "restores the committed theme when leaving a theme row" do
      items = [theme_item("nord"), %{id: "action:other"}]

      s =
        socket(%{
          palette_items: items,
          palette_selected_idx: 0,
          palette_open: true,
          palette_theme_preview_id: "nord",
          terminal_themes: %{preset: "nord", preview: true}
        })

      {:noreply, restored} =
        PaletteEvents.handle_event("palette:nav", %{"dir" => "down"}, s)

      assert restored.assigns.palette_selected_idx == 1
      assert restored.assigns.palette_theme_preview_id == nil
      assert restored.assigns.terminal_preset_id == "catppuccin"
      assert restored.assigns.terminal_themes.preset == "catppuccin"
      assert restored.assigns.terminal_themes.preview == false
    end
  end

  describe "palette:close" do
    test "restores a provisional theme preview on cancel" do
      s =
        socket(%{
          palette_open: true,
          palette_theme_preview_id: "nord",
          terminal_themes: %{preset: "nord", preview: true}
        })

      {:noreply, closed} = PaletteEvents.handle_event("palette:close", %{}, s)

      assert closed.assigns.palette_open == false
      assert closed.assigns.palette_theme_preview_id == nil
      assert closed.assigns.terminal_preset_id == "catppuccin"
      assert closed.assigns.terminal_themes.preset == "catppuccin"
    end
  end

  describe "palette:execute" do
    test "empty _selected_id closes the palette without dispatching" do
      s = socket(%{palette_open: true})

      {:noreply, socket} =
        PaletteEvents.handle_event("palette:execute", %{"_selected_id" => ""}, s)

      assert socket.assigns.palette_open == false
    end

    test "empty _selected_id restores an active theme preview" do
      s =
        socket(%{
          palette_open: true,
          palette_theme_preview_id: "nord",
          terminal_themes: %{preset: "nord", preview: true}
        })

      {:noreply, socket} =
        PaletteEvents.handle_event("palette:execute", %{"_selected_id" => ""}, s)

      assert socket.assigns.palette_open == false
      assert socket.assigns.palette_theme_preview_id == nil
      assert socket.assigns.terminal_themes.preset == "catppuccin"
    end

    test "confirming a theme row commits the preset" do
      s =
        socket(%{
          palette_open: true,
          palette_theme_preview_id: "nord",
          terminal_themes: %{preset: "nord", preview: true}
        })

      {:noreply, socket} =
        PaletteEvents.handle_event("palette:execute", %{"id" => "terminal:theme:nord"}, s)

      assert socket.assigns.palette_open == false
      assert socket.assigns.palette_theme_preview_id == nil
      assert socket.assigns.terminal_preset_id == "nord"
      assert socket.assigns.terminal_themes.preset == "nord"
      assert socket.assigns.terminal_themes.preview == false
    end

    test "unknown id closes the palette without recording usage" do
      workspace_id = "ws-palette-#{System.unique_integer([:positive])}"
      s = socket(%{workspace: %{id: workspace_id}, palette_open: true})

      {:noreply, socket} =
        PaletteEvents.handle_event(
          "palette:execute",
          %{"id" => "unknown:does-not-exist-#{System.unique_integer([:positive])}"},
          s
        )

      assert socket.assigns.palette_open == false
      assert Usage.for_workspace(workspace_id) == %{}
    end

    test "resolved workflow:hint closes the palette, dispatches, and records frecency" do
      workspace_id = "ws-palette-#{System.unique_integer([:positive])}"
      item_id = "workflow:hint:fixture-#{System.unique_integer([:positive])}"

      s =
        socket(%{
          workspace: %{id: workspace_id},
          palette_open: true,
          flash: %{}
        })

      {:noreply, socket} =
        PaletteEvents.handle_event("palette:execute", %{"id" => item_id}, s)

      assert socket.assigns.palette_open == false

      assert Phoenix.Flash.get(socket.assigns.flash, :info) =~
               "workflow needs a bit more detail"

      usage = Usage.for_workspace(workspace_id)
      assert map_size(usage) > 0
      assert Map.has_key?(usage, item_id)
    end
  end
end
