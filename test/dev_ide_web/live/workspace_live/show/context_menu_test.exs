defmodule DevIdeWeb.WorkspaceLive.Show.ContextMenuTest do
  use DevIDE.TestCase, async: true

  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceLive.Show.ContextMenu
  alias DevIdeWeb.WorkspaceLive.Show.ContextMenuEvents

  # items/3 and the ctx:* handlers are pure given assigns. Flat peer model:
  # any authenticated identity may mutate; empty identity is read-only.
  defp owner_assigns(extra \\ %{}) do
    Map.merge(
      %{
        workspace: %{id: "ws-ctx-#{System.unique_integer([:positive])}", user: "alice"},
        current_user: %{id: "u1", username: "alice"},
        selected_dir: ""
      },
      extra
    )
  end

  defp viewer_assigns(extra \\ %{}) do
    owner_assigns(Map.merge(%{current_user: %{}}, extra))
  end

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  defp item_ids(items), do: items |> Enum.reject(& &1[:divider]) |> Enum.map(& &1.id)

  defp mutations, do: %{tmux_mutations_enabled?: true}

  describe "items/3" do
    test "file node menu for an owner includes mutations" do
      items =
        ContextMenu.items("tree_node", %{"path" => "lib/a.ex", "kind" => "file"}, owner_assigns())

      assert item_ids(items) == ["open", "copy-path", "rename", "duplicate", "delete"]
      assert Enum.find(items, &(&1[:id] == "delete")).danger
      assert Enum.find(items, &(&1[:id] == "copy-path")).copy == "lib/a.ex"
    end

    test "file node menu for a viewer is read-only" do
      items =
        ContextMenu.items(
          "tree_node",
          %{"path" => "lib/a.ex", "kind" => "file"},
          viewer_assigns()
        )

      assert item_ids(items) == ["open", "copy-path"]
    end

    test "dir node menu for an owner offers new file/folder scoped to the dir" do
      items = ContextMenu.items("tree_node", %{"path" => "lib", "kind" => "dir"}, owner_assigns())

      assert item_ids(items) ==
               ["toggle", "copy-path", "new-file", "new-dir", "rename", "duplicate", "delete"]

      new_file = Enum.find(items, &(&1[:id] == "new-file"))
      assert new_file.event == "tree:new_form_at"
      assert new_file.params == %{"dir" => "lib", "kind" => "file"}
    end

    test "tree root menu follows the selected dir and the edit gate" do
      owner = ContextMenu.items("tree_root", %{}, owner_assigns(%{selected_dir: "lib"}))
      assert item_ids(owner) == ["new-file", "new-dir", "refresh"]
      assert Enum.find(owner, &(&1[:id] == "new-file")).params["dir"] == "lib"

      viewer = ContextMenu.items("tree_root", %{}, viewer_assigns())
      assert item_ids(viewer) == ["refresh"]
    end

    test "unknown menus and malformed ctx build no items" do
      assert ContextMenu.items("nope", %{}, owner_assigns()) == []
      assert ContextMenu.items("tree_node", %{}, owner_assigns()) == []

      assert ContextMenu.items("tree_node", %{"path" => "x", "kind" => "weird"}, owner_assigns()) ==
               []
    end

    test "session tab menu gates kill on tmux mutations and a tmux target" do
      ctx = %{"sessionId" => "s1", "kind" => "tmux", "tmuxSession" => "ws-a", "href" => "/w/1"}

      with_mutations = ContextMenu.items("session_tab", ctx, owner_assigns(mutations()))
      assert item_ids(with_mutations) == ["attach", "open-tab", "kill"]
      assert Enum.find(with_mutations, &(&1[:id] == "kill")).confirm =~ "Kill this tmux session"

      without_mutations = ContextMenu.items("session_tab", ctx, owner_assigns())
      assert item_ids(without_mutations) == ["attach", "open-tab"]

      no_tmux =
        ContextMenu.items(
          "session_tab",
          Map.delete(ctx, "tmuxSession"),
          owner_assigns(mutations())
        )

      assert item_ids(no_tmux) == ["attach", "open-tab"]
    end

    test "session tab menu refuses non-relative hrefs" do
      base = %{"sessionId" => "s1", "kind" => "tmux"}

      for href <- ["javascript:alert(1)", "https://evil.example", "//evil.example"] do
        items = ContextMenu.items("session_tab", Map.put(base, "href", href), owner_assigns())
        refute "open-tab" in item_ids(items)
      end
    end

    test "window tab menu maps to existing tmux events" do
      ctx = %{"windowId" => "@3", "href" => "/w/1?window=@3"}

      windows = [
        %{id: "@1", index: 0},
        %{id: "@2", index: 1},
        %{id: "@3", index: 2}
      ]

      with_mutations =
        ContextMenu.items(
          "window_tab",
          ctx,
          owner_assigns(Map.merge(mutations(), %{tmux_windows: windows}))
        )

      assert item_ids(with_mutations) ==
               ["select", "open-tab", "rename", "move-left", "move-right", "new-window", "kill"]

      move_left = Enum.find(with_mutations, &(&1[:id] == "move-left"))
      assert move_left.event == "tmux:move_window"
      assert move_left.params == %{"window-id" => "@3", "dir" => "left"}
      refute move_left.disabled

      move_right = Enum.find(with_mutations, &(&1[:id] == "move-right"))
      assert move_right.disabled

      kill = Enum.find(with_mutations, &(&1[:id] == "kill"))
      assert kill.event == "tmux:kill_window"
      assert kill.params == %{"window-id" => "@3"}

      without_mutations = ContextMenu.items("window_tab", ctx, owner_assigns())
      assert item_ids(without_mutations) == ["select", "open-tab"]
    end

    test "window tab move items are disabled at the strip edges" do
      ctx = %{"windowId" => "@1", "href" => "/w/1?window=@1"}
      windows = [%{id: "@1", index: 0}, %{id: "@2", index: 1}]

      items =
        ContextMenu.items(
          "window_tab",
          ctx,
          owner_assigns(Map.merge(mutations(), %{tmux_windows: windows}))
        )

      assert Enum.find(items, &(&1[:id] == "move-left")).disabled
      refute Enum.find(items, &(&1[:id] == "move-right")).disabled
    end

    test "terminal menu builds client actions against a quoted attribute selector" do
      ctx = %{"targetId" => "ghostty-%12", "hasSelection" => "false", "paneId" => "%12"}
      items = ContextMenu.items("terminal", ctx, owner_assigns(mutations()))

      assert item_ids(items) ==
               [
                 "copy",
                 "paste",
                 "select-all",
                 "clear",
                 "history",
                 "split-right",
                 "split-down",
                 "zoom",
                 "kill-pane"
               ]

      copy = Enum.find(items, &(&1[:id] == "copy"))
      assert copy.disabled
      assert copy.target == "[id='ghostty-%12']"

      with_selection =
        ContextMenu.items(
          "terminal",
          %{ctx | "hasSelection" => "true"},
          owner_assigns(mutations())
        )

      refute Enum.find(with_selection, &(&1[:id] == "copy")).disabled
    end

    test "terminal menu without mutations keeps history but drops pane mutations" do
      ctx = %{"targetId" => "ghostty-%12", "hasSelection" => "true", "paneId" => "%12"}
      items = ContextMenu.items("terminal", ctx, owner_assigns())

      assert item_ids(items) == ["copy", "paste", "select-all", "clear", "history"]
    end

    test "terminal menu refuses selector-breaking target ids" do
      for bad <- ["a'] *", "a[b]", "a b", "'", ""] do
        assert ContextMenu.items(
                 "terminal",
                 %{"targetId" => bad, "hasSelection" => "true"},
                 owner_assigns()
               ) == []
      end
    end

    test "editor menu needs an open file and gates edit/agent items" do
      base = %{"targetId" => "file-viewer", "hasFile" => "true", "hasSelection" => "true"}

      assert ContextMenu.items("editor", %{base | "hasFile" => "false"}, owner_assigns()) == []

      full = ContextMenu.items("editor", base, owner_assigns(mutations()))

      assert item_ids(full) ==
               [
                 "cut",
                 "copy",
                 "paste",
                 "select-all",
                 "save",
                 "rename",
                 "delete",
                 "send-agent",
                 "explain"
               ]

      viewer = ContextMenu.items("editor", base, viewer_assigns())
      assert item_ids(viewer) == ["cut", "copy", "paste", "select-all"]
      assert Enum.find(viewer, &(&1[:id] == "cut")).disabled
      assert Enum.find(viewer, &(&1[:id] == "paste")).disabled
      refute Enum.find(viewer, &(&1[:id] == "copy")).disabled
    end

    test "file pane editor menu scopes clipboard/save to the pane and copies the path" do
      base = %{
        "targetId" => "file-pane-abc",
        "hasFile" => "true",
        "hasSelection" => "true",
        "path" => "lib/foo.ex"
      }

      assert ContextMenu.items(
               "file_pane_editor",
               %{base | "hasFile" => "false"},
               owner_assigns()
             ) ==
               []

      full = ContextMenu.items("file_pane_editor", base, owner_assigns(mutations()))

      assert item_ids(full) ==
               [
                 "cut",
                 "copy",
                 "paste",
                 "select-all",
                 "save",
                 "copy-path",
                 "send-agent",
                 "explain"
               ]

      # Client actions target the pane overlay root by quoted attribute selector,
      # never a bare #id (pane ids carry "%").
      assert Enum.find(full, &(&1[:id] == "copy")).target == "[id='file-pane-abc']"
      assert Enum.find(full, &(&1[:id] == "copy-path")).copy == "lib/foo.ex"

      # Viewer: no save, no agent items; clipboard cut/paste disabled.
      viewer = ContextMenu.items("file_pane_editor", base, viewer_assigns())
      assert item_ids(viewer) == ["cut", "copy", "paste", "select-all", "copy-path"]
      assert Enum.find(viewer, &(&1[:id] == "cut")).disabled
      assert Enum.find(viewer, &(&1[:id] == "paste")).disabled

      # No agent items without a selection.
      no_sel =
        ContextMenu.items(
          "file_pane_editor",
          %{base | "hasSelection" => "false"},
          owner_assigns(mutations())
        )

      refute "send-agent" in item_ids(no_sel)
    end

    test "file pane tab menu carries the tab path in close actions and copy" do
      items =
        ContextMenu.items(
          "file_pane_tab",
          %{"path" => "lib/foo.ex", "targetId" => "file-pane-abc"},
          owner_assigns()
        )

      assert item_ids(items) == ["close", "close-others", "copy-path"]

      close = Enum.find(items, &(&1[:id] == "close"))
      assert close.action == "close_tab"
      assert close.target == "[id='file-pane-abc']"
      assert close.detail == %{path: "lib/foo.ex"}

      assert Enum.find(items, &(&1[:id] == "close-others")).detail == %{path: "lib/foo.ex"}
      assert Enum.find(items, &(&1[:id] == "copy-path")).copy == "lib/foo.ex"

      # A malformed target id builds nothing.
      assert ContextMenu.items(
               "file_pane_tab",
               %{"path" => "lib/foo.ex", "targetId" => "bad id!"},
               owner_assigns()
             ) == []
    end

    test "preview pane menu pushes gated preview events and carries the url" do
      full =
        ContextMenu.items(
          "preview_pane",
          %{"paneId" => "%7", "url" => "https://ws.example.test/app"},
          owner_assigns()
        )

      assert item_ids(full) == [
               "reload",
               "reopen",
               "viewport-phone",
               "viewport-tablet",
               "viewport-desktop",
               "viewport-fit",
               "copy-url",
               "open-tab",
               "close"
             ]

      reload = Enum.find(full, &(&1[:id] == "reload"))
      assert reload.event == "preview-pane:refresh"
      assert reload.params == %{"pane-id" => "%7"}

      assert Enum.find(full, &(&1[:id] == "close")).event == "preview-pane:close"
      assert Enum.find(full, &(&1[:id] == "copy-url")).copy == "https://ws.example.test/app"
      assert Enum.find(full, &(&1[:id] == "open-tab")).href == "https://ws.example.test/app"
    end

    test "preview pane menu omits url items for a missing or non-http url" do
      no_url = ContextMenu.items("preview_pane", %{"paneId" => "%7"}, owner_assigns())

      assert item_ids(no_url) == [
               "reload",
               "reopen",
               "viewport-phone",
               "viewport-tablet",
               "viewport-desktop",
               "viewport-fit",
               "close"
             ]

      # A crafted javascript:/relative url still yields no anchor (scheme guard),
      # though the harmless clipboard copy is kept.
      for bad <- ["javascript:alert(1)", "/relative/path", "data:text/html,x"] do
        items =
          ContextMenu.items("preview_pane", %{"paneId" => "%7", "url" => bad}, owner_assigns())

        refute "open-tab" in item_ids(items)
      end

      assert ContextMenu.items("preview_pane", %{}, owner_assigns()) == []
    end

    test "preview pane viewport presets route through the authorized pane:input event" do
      items = ContextMenu.items("preview_pane", %{"paneId" => "%7"}, owner_assigns())
      phone = Enum.find(items, &(&1[:id] == "viewport-phone"))

      # pane:input, not a new preview-pane:* name — it is the route that carries
      # pane authorization (DevIDE.Panes.get_by_pane/1 + workspace match).
      assert phone.event == "pane:input"

      assert phone.params == %{
               "pane-id" => "%7",
               "type" => "set_viewport",
               "viewport" => "390x844"
             }

      # "Fit pane" clears the lock rather than setting a size.
      assert Enum.find(items, &(&1[:id] == "viewport-fit")).params["viewport"] == ""
    end

    test "preview pane viewport menu disables the preset already applied" do
      items =
        ContextMenu.items(
          "preview_pane",
          %{"paneId" => "%7", "viewport" => "390x844"},
          owner_assigns()
        )

      assert Enum.find(items, &(&1[:id] == "viewport-phone"))[:disabled]
      refute Enum.find(items, &(&1[:id] == "viewport-tablet"))[:disabled]
      # No locked viewport yet, so "Fit pane" is the state already in effect.
      refute Enum.find(items, &(&1[:id] == "viewport-fit"))[:disabled]

      unlocked = ContextMenu.items("preview_pane", %{"paneId" => "%7"}, owner_assigns())
      assert Enum.find(unlocked, &(&1[:id] == "viewport-fit"))[:disabled]
      refute Enum.find(unlocked, &(&1[:id] == "viewport-phone"))[:disabled]
    end

    test "preview pane viewport menu tolerates a malformed current viewport" do
      # data-ctx-viewport is rendered from the registration, but a stale or
      # hand-crafted ctx must not disable everything or crash the build.
      for bad <- ["garbage", "390X844", 390, nil] do
        items =
          ContextMenu.items(
            "preview_pane",
            %{"paneId" => "%7", "viewport" => bad},
            owner_assigns()
          )

        assert "viewport-phone" in item_ids(items)
      end

      # Case-insensitive match still counts as "already applied".
      upper =
        ContextMenu.items(
          "preview_pane",
          %{"paneId" => "%7", "viewport" => "390X844"},
          owner_assigns()
        )

      assert Enum.find(upper, &(&1[:id] == "viewport-phone"))[:disabled]
    end

    test "run entry menu offers rerun only when a command id exists" do
      with_command =
        ContextMenu.items(
          "run_entry",
          %{"runId" => "r1", "commandId" => "mix.test"},
          owner_assigns()
        )

      assert item_ids(with_command) == ["select", "copy-run-id", "rerun", "copy-command-id"]

      without_command = ContextMenu.items("run_entry", %{"runId" => "r1"}, owner_assigns())
      assert item_ids(without_command) == ["select", "copy-run-id"]
    end
  end

  describe "ctx:open / ctx:close" do
    test "ctx:open assigns the menu with server-built items and clamped coords" do
      s = socket(owner_assigns(%{context_menu: nil}))

      params = %{
        "menu" => "tree_node",
        "ctx" => %{"path" => "lib/a.ex", "kind" => "file"},
        "x" => -5,
        "y" => 12.7
      }

      assert {:reply, %{}, s2} = ContextMenuEvents.handle_event("ctx:open", params, s)
      assert %{menu: "tree_node", x: 0, y: 13, items: items} = s2.assigns.context_menu
      assert "rename" in item_ids(items)
    end

    test "ctx:open with an unknown menu closes instead of opening" do
      s = socket(owner_assigns(%{context_menu: %{menu: "tree_root"}}))
      params = %{"menu" => "nope", "ctx" => %{}, "x" => 1, "y" => 1}

      assert {:reply, %{}, s2} = ContextMenuEvents.handle_event("ctx:open", params, s)
      assert s2.assigns.context_menu == nil
    end

    test "ctx:open drops non-string ctx values" do
      s = socket(owner_assigns(%{context_menu: nil}))

      params = %{
        "menu" => "tree_node",
        "ctx" => %{"path" => 123, "kind" => "file"},
        "x" => 1,
        "y" => 1
      }

      assert {:reply, %{}, s2} = ContextMenuEvents.handle_event("ctx:open", params, s)
      assert s2.assigns.context_menu == nil
    end

    test "ctx:close clears the menu" do
      s = socket(%{context_menu: %{menu: "tree_root"}})
      assert {:noreply, s2} = ContextMenuEvents.handle_event("ctx:close", %{}, s)
      assert s2.assigns.context_menu == nil
    end
  end

  describe "render_context_menu/1" do
    test "renders nothing when closed" do
      html = render_component(&ContextMenu.render_context_menu/1, context_menu: nil)
      refute html =~ ~s(id="ctx-menu" )
    end

    test "renders server items, copy items, and dividers" do
      menu = %{
        menu: "tree_node",
        ctx: %{},
        x: 40,
        y: 60,
        items: [
          %{id: "open", label: "Open", event: "tree:open", params: %{"path" => "a.ex"}},
          %{divider: true},
          %{id: "copy-path", label: "Copy path", copy: "a.ex"},
          %{
            id: "delete",
            label: "Delete…",
            event: "tree:delete_node_request",
            params: %{"path" => "a.ex"},
            danger: true
          }
        ]
      }

      html = render_component(&ContextMenu.render_context_menu/1, context_menu: menu)

      assert html =~ ~s(role="menu")
      assert html =~ "left: 40px; top: 60px;"
      assert html =~ ~s(id="ctx-item-open")
      assert html =~ ~s(role="separator")
      assert html =~ ~s(data-copy-text="a.ex")
      assert html =~ ~s(phx-hook="CopyText")
      assert html =~ "text-error"
      assert html =~ ~s(phx-click-away="ctx:close")
    end

    test "renders href, action, and confirm item variants" do
      menu = %{
        menu: "window_tab",
        ctx: %{},
        x: 0,
        y: 0,
        items: [
          %{id: "open-tab", label: "Open in new tab", href: "/w/1"},
          %{id: "copy", label: "Copy", action: "copy", target: "[id='ghostty-%12']"},
          %{
            id: "kill",
            label: "Close window…",
            event: "tmux:kill_window",
            params: %{"window-id" => "@3"},
            confirm: "Kill this window?",
            danger: true
          }
        ]
      }

      html = render_component(&ContextMenu.render_context_menu/1, context_menu: menu)

      assert html =~ ~s(href="/w/1")
      assert html =~ ~s(target="_blank")
      assert html =~ "devide:ctx-action"
      assert html =~ ~s(data-confirm="Kill this window?")
    end
  end
end
