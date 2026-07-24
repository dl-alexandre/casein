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
            palette_usage: %{}
          },
          assigns
        )
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
  end

  describe "palette:execute" do
    test "empty _selected_id closes the palette without dispatching" do
      s = socket(%{palette_open: true})

      {:noreply, socket} =
        PaletteEvents.handle_event("palette:execute", %{"_selected_id" => ""}, s)

      assert socket.assigns.palette_open == false
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
