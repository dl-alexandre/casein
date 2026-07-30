defmodule CaseinWeb.WorkspaceLive.Show.ClipboardDrawerEventsTest do
  # Casein.Terminals.ClipboardHistory is a singleton GenServer.
  use Casein.TestCase, async: false

  alias Casein.Terminals.ClipboardHistory
  alias CaseinWeb.WorkspaceLive.Show.ClipboardDrawer
  alias CaseinWeb.WorkspaceLive.Show.ClipboardDrawerEvents

  import Phoenix.LiveViewTest, only: [render_component: 2]

  setup do
    ClipboardHistory.clear()
    on_exit(fn -> ClipboardHistory.clear() end)
    :ok
  end

  defp socket(assigns \\ %{}) do
    ws_id = "ws-clipboard-#{System.unique_integer([:positive])}"

    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: ws_id},
            tmux_session: "casein_test",
            pane_labels: %{}
          },
          assigns
        )
    }
  end

  test "mount seeds a closed, unloaded drawer without reading the store" do
    s = ClipboardDrawerEvents.mount(socket())

    assert s.assigns.clipboard_drawer_open == false
    assert s.assigns.clipboard_loaded? == false
    assert s.assigns.clipboard_entries == []
    # Disconnected mount must not pay for a store read.
    assert s.assigns.clipboard_count == 0
  end

  test "record stores the copy against the mounted workspace" do
    s = socket()
    ws_id = s.assigns.workspace.id

    ClipboardDrawerEvents.record(s, "%3", "git status")

    assert [entry] = ClipboardHistory.recent(ws_id)
    assert entry.text == "git status"
    assert entry.pane_id == "%3"
  end

  test "record attributes the copy to the pane's label when one is known" do
    key = Casein.Labels.key("casein_test", "%3")
    s = socket(%{pane_labels: %{key => %{label: "claude"}}})

    ClipboardDrawerEvents.record(s, "%3", "labelled")

    assert [entry] = ClipboardHistory.recent(s.assigns.workspace.id)
    assert entry.pane_label == "claude"
  end

  test "record is a no-op when there is no workspace to attribute it to" do
    s = socket(%{workspace: nil})
    assert %Phoenix.LiveView.Socket{} = ClipboardDrawerEvents.record(s, "%3", "orphan")
  end

  test "record returns the socket so it can sit in the OSC 52 reduce" do
    s = socket()
    assert ClipboardDrawerEvents.record(s, "%3", "text") == s
  end

  test "toggle opens and closes the drawer" do
    s = ClipboardDrawerEvents.mount(socket())

    {:noreply, opened} = ClipboardDrawerEvents.handle_event("clipboard:toggle", %{}, s)
    assert opened.assigns.clipboard_drawer_open

    {:noreply, closed} = ClipboardDrawerEvents.handle_event("clipboard:toggle", %{}, opened)
    refute closed.assigns.clipboard_drawer_open
  end

  test "opening a disconnected socket does not load the payloads" do
    s = ClipboardDrawerEvents.mount(socket())
    ClipboardDrawerEvents.record(s, "%3", "not loaded yet")

    {:noreply, opened} = ClipboardDrawerEvents.handle_event("clipboard:toggle", %{}, s)

    assert opened.assigns.clipboard_drawer_open
    assert opened.assigns.clipboard_loaded? == false
    assert opened.assigns.clipboard_entries == []
  end

  test "refresh loads the retained copies newest first" do
    s = ClipboardDrawerEvents.mount(socket())
    ClipboardDrawerEvents.record(s, "%3", "older")
    ClipboardDrawerEvents.record(s, "%3", "newer")

    {:noreply, refreshed} = ClipboardDrawerEvents.handle_event("clipboard:refresh", %{}, s)

    assert refreshed.assigns.clipboard_loaded?
    assert ["newer", "older"] = Enum.map(refreshed.assigns.clipboard_entries, & &1.text)
    assert refreshed.assigns.clipboard_count == 2
  end

  test "clear forgets this workspace's copies" do
    s = ClipboardDrawerEvents.mount(socket())
    ws_id = s.assigns.workspace.id
    ClipboardDrawerEvents.record(s, "%3", "sensitive")

    {:noreply, cleared} = ClipboardDrawerEvents.handle_event("clipboard:clear", %{}, s)

    assert cleared.assigns.clipboard_entries == []
    assert cleared.assigns.clipboard_count == 0
    assert ClipboardHistory.recent(ws_id) == []
  end

  test "a broadcast refreshes the list only while the drawer is open" do
    s = ClipboardDrawerEvents.mount(socket())
    ClipboardDrawerEvents.record(s, "%3", "copied")

    # Closed: the list stays empty (the payloads are not pulled into assigns).
    closed = ClipboardDrawerEvents.handle_history_change(s)
    assert closed.assigns.clipboard_entries == []

    {:noreply, opened} = ClipboardDrawerEvents.handle_event("clipboard:refresh", %{}, s)
    opened = %{opened | assigns: Map.put(opened.assigns, :clipboard_drawer_open, true)}

    ClipboardDrawerEvents.record(s, "%3", "copied again")
    refreshed = ClipboardDrawerEvents.handle_history_change(opened)

    assert ["copied again", "copied"] = Enum.map(refreshed.assigns.clipboard_entries, & &1.text)
  end

  describe "rendering" do
    test "renders each copy with its own copy button" do
      entry = %{
        id: "entry-1",
        pane_id: "%3",
        pane_label: "claude",
        text: "mix test --stale",
        truncated?: false,
        inserted_at: DateTime.utc_now()
      }

      html =
        render_component(&ClipboardDrawer.clipboard_drawer/1,
          open: true,
          entries: [entry],
          count: 1
        )

      assert html =~ ~s(id="clipboard-drawer")
      assert html =~ ~s(id="clipboard-copy-entry-1")
      # The full text has to reach the DOM: the copy must happen inside the
      # click, and a server round-trip would land outside the user gesture.
      assert html =~ "mix test --stale"
      assert html =~ "claude"
      assert html =~ "1 recent copy from agents"
    end

    test "renders nothing when closed" do
      html =
        render_component(&ClipboardDrawer.clipboard_drawer/1, open: false, entries: [], count: 0)

      refute html =~ ~s(id="clipboard-drawer")
    end

    test "shows an empty state that explains what lands here" do
      html =
        render_component(&ClipboardDrawer.clipboard_drawer/1, open: true, entries: [], count: 0)

      assert html =~ ~s(id="clipboard-empty")
      assert html =~ "Nothing copied yet"
      # Nothing to clear, so no destructive control.
      refute html =~ ~s(id="clipboard-clear")
    end

    test "flags a truncated copy so the operator knows it is not the whole thing" do
      entry = %{
        id: "entry-2",
        pane_id: "%3",
        pane_label: nil,
        text: "partial",
        truncated?: true,
        inserted_at: DateTime.utc_now()
      }

      html =
        render_component(&ClipboardDrawer.clipboard_drawer/1,
          open: true,
          entries: [entry],
          count: 1
        )

      assert html =~ "Truncated"
      # No label — falls back to the pane id rather than rendering nothing.
      assert html =~ "%3"
    end
  end
end
