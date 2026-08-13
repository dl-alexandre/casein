defmodule CaseinWeb.WorkspaceLive.Show.LeaderBindingsTest do
  use Casein.TestCase, async: true

  alias Casein.CommandPalette.Actions
  alias CaseinWeb.WorkspaceLive.Show.LeaderBindings, as: Bindings

  describe "key_map/0" do
    test "matches the tmux bindings the JS module used to hold literally" do
      # Frozen copy of the removed LEADER_ACTIONS object. The hook now reads
      # this map off data-leader-bindings, so a typo here silently kills a key
      # for every user — hence pinning the whole map rather than spot-checks.
      assert Bindings.key_map() == %{
               "s" => "session-picker",
               "w" => "window-picker",
               "(" => "prev-session",
               ")" => "next-session",
               "c" => "new-window",
               "C" => "new-window-tab",
               "n" => "next-window",
               "p" => "prev-window",
               "l" => "last-window",
               "y" => "copy-link",
               "d" => "detach",
               # #952: jump to the next needs-you pane. New key, not a rebinding
               # — `a` was unclaimed here and in tmux's own keymap.
               "a" => "jump-needs-you",
               "o" => "pane-next",
               "{" => "pane-swap-previous",
               "}" => "pane-swap-next",
               ";" => "last-pane",
               ":" => "palette",
               "?" => "help",
               "&" => "kill-window",
               "%" => "split-right",
               "|" => "split-right",
               "\"" => "split-down",
               "-" => "split-down",
               "z" => "zoom",
               "x" => "close-pane",
               "q" => "pane-overlay",
               "," => "rename-window",
               "r" => "restore-window",
               "$" => "rename-session",
               "ArrowLeft" => "pane-left",
               "ArrowRight" => "pane-right",
               "ArrowUp" => "pane-up",
               "ArrowDown" => "pane-down"
             }
    end

    test "binds each key exactly once" do
      keys = Enum.flat_map(Bindings.all(), & &1.keys)

      assert keys == Enum.uniq(keys), "a key bound twice would dispatch unpredictably"
    end

    test "is JSON-encodable for the hook data attribute" do
      assert {:ok, json} = Jason.encode(Bindings.key_map())
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["%"] == "split-right"
    end
  end

  describe "entry shape" do
    test "every entry declares a group, display, and description" do
      for binding <- Bindings.all() do
        assert binding.group in [:sessions, :panes, :more]
        assert is_binary(binding.display) and binding.display != ""
        assert is_binary(binding.desc) and binding.desc != ""
      end
    end

    test "keys and actions pair legally" do
      # Either one action shared by synonym keys, or a positional zip.
      for %{keys: keys, actions: actions} <- Bindings.all() do
        assert actions == [] or length(actions) == 1 or length(actions) == length(keys)
      end
    end

    test "documentation-only rows declare no action" do
      # 0-9 and Esc are dispatched by their own paths in the hook.
      for %{keys: [], actions: actions} <- Bindings.all(), do: assert(actions == [])
    end
  end

  describe "hint_for/1 and hint_for_action/1" do
    test "resolves hints for leader-bound palette items" do
      assert Bindings.hint_for("tmux:zoom") == "C-b z"
      assert Bindings.hint_for("tmux:split_right") == "C-b %"
      assert Bindings.hint_for("tmux:new_window") == "C-b c"
    end

    test "returns nil for unbound items" do
      assert Bindings.hint_for("tmux:consolidate_sessions") == nil
    end

    test "prefers the canonical key when an action has synonyms" do
      # "|" also splits right; the hint must not flap between the two.
      assert Bindings.hint_for_action("split-right") == "C-b %"
      assert Bindings.hint_for_action("split-down") == "C-b \""
    end

    test "gives each half of a paired entry its own key" do
      # "{" and "}" share one entry; showing both items "C-b {" would be wrong.
      assert Bindings.hint_for("tmux:swap_previous") == "C-b {"
      assert Bindings.hint_for("tmux:swap_next") == "C-b }"
      assert Bindings.key_for_action("pane-swap-next") == "}"
    end

    test "resolves the dynamic items that cannot match on id" do
      assert Bindings.hint_for_action("rename-window") == "C-b ,"
      assert Bindings.hint_for_action("rename-session") == "C-b $"
      assert Bindings.hint_for_action("detach") == "C-b d"
    end

    test "key_for_action/1 returns the bare key for chrome glyphs" do
      assert Bindings.key_for_action("zoom") == "z"
      assert Bindings.key_for_action("split-right") == "%"
      assert Bindings.key_for_action("nope") == nil
    end
  end

  describe "decorate/1" do
    test "sets hints on catalog items without touching unbound ones" do
      by_id = Actions.all() |> Bindings.decorate() |> Map.new(&{&1.id, &1})

      assert by_id["tmux:zoom"].hint == "C-b z"
      assert by_id["tmux:close_pane"].hint == "C-b x"
      assert by_id["tmux:consolidate_sessions"].hint == nil
    end

    test "every palette_ids entry names a real catalog item" do
      # A stale id would silently stop showing its hint.
      catalog = MapSet.new(Actions.all(), & &1.id)
      dynamic = MapSet.new(["session:switch:shell"])

      unknown =
        Bindings.all()
        |> Enum.flat_map(&Map.get(&1, :palette_ids, []))
        |> Enum.reject(&(MapSet.member?(catalog, &1) or MapSet.member?(dynamic, &1)))

      assert unknown == []
    end
  end

  describe "groups/0" do
    test "covers every binding exactly once, in table order" do
      grouped = Bindings.groups() |> Enum.flat_map(& &1.rows)

      assert grouped == Bindings.all()
    end

    test "each group carries a label for the cheatsheet heading" do
      for group <- Bindings.groups() do
        assert is_binary(group.label) and group.label != ""
        assert group.rows != []
      end
    end
  end

  describe "dispatch_actions/0" do
    test "lists only actions the shell renders a hidden button for" do
      actions = Bindings.dispatch_actions()

      assert "split-right" in actions
      assert "zoom" in actions
      # Pickers need visible chrome; pane-overlay never leaves the browser.
      refute "session-picker" in actions
      refute "window-picker" in actions
      refute "pane-overlay" in actions
    end

    test "every dispatch action has a target button in the shell" do
      # The table says which key reaches an action; WorkspaceShell renders the
      # element that key clicks. A binding with no button is a dead key, and
      # neither file can notice that alone — so assert against the markup.
      # Some buttons render conditionally, hence matching source rather than a
      # live render (which would only ever cover the always-visible subset).
      shell = File.read!("lib/casein_web/live/workspace_live/show/workspace_shell.ex")

      missing =
        Enum.reject(
          Bindings.dispatch_actions(),
          &String.contains?(shell, ~s(data-leader-action="#{&1}"))
        )

      assert missing == [], "leader keys bound with no dispatch button: #{inspect(missing)}"
    end
  end
end
