defmodule DevIDE.PaletteTest do
  use ExUnit.Case, async: true

  alias DevIDE.Palette
  alias DevIDE.Palette.{Actions, FileIndex, Fuzzy, Item}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pal-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    _ = File.rm_rf!(root)
    File.mkdir_p!(Path.join([root, "lib", "dev_ide"]))
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.mkdir_p!(Path.join(root, "deps"))
    File.mkdir_p!(Path.join(root, "node_modules"))
    File.write!(Path.join([root, "lib", "dev_ide", "foo.ex"]), "")
    File.write!(Path.join([root, "lib", "bar.ex"]), "")
    File.write!(Path.join(root, "README.md"), "")
    File.write!(Path.join([root, ".git", "config"]), "")
    File.write!(Path.join([root, "_build", "ignored.ex"]), "")
    File.write!(Path.join([root, "deps", "ignored.ex"]), "")
    File.write!(Path.join([root, "node_modules", "ignored.js"]), "")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  ## Fuzzy

  test "exact match scores higher than substring" do
    a = Fuzzy.score("foo", "foo")
    b = Fuzzy.score("xfoox", "foo")
    assert a > b
  end

  test "starts-with beats scattered" do
    a = Fuzzy.score("foobar", "foo")
    b = Fuzzy.score("xfxoxoxbar", "foo")
    assert a > b
  end

  test "shorter target wins ties" do
    a = Fuzzy.score("a.ex", "a")
    b = Fuzzy.score("longer/a.ex", "a")
    assert a > b
  end

  test "non-matching returns nil" do
    assert is_nil(Fuzzy.score("foo", "zzz"))
  end

  test "empty query returns base score" do
    assert Fuzzy.score("anything", "") == 1
  end

  ## FileIndex

  test "FileIndex skips ignored dirs and lists workspace files", %{root: root} do
    files = FileIndex.list(root)
    assert "lib/dev_ide/foo.ex" in files
    assert "lib/bar.ex" in files
    assert "README.md" in files
    refute Enum.any?(files, &String.starts_with?(&1, ".git/"))
    refute Enum.any?(files, &String.starts_with?(&1, "_build/"))
    refute Enum.any?(files, &String.starts_with?(&1, "deps/"))
    refute Enum.any?(files, &String.starts_with?(&1, "node_modules/"))
  end

  ## Actions

  test "Actions.all/0 includes only allowlisted commands" do
    items = Actions.all()
    cmds = Enum.filter(items, &(&1.kind == :command)) |> Enum.map(&Map.get(&1.payload, :params))
    cmd_ids = Enum.map(cmds, & &1["id"])

    for id <- cmd_ids do
      assert DevIDE.Commands.allowed?(id), "command id #{id} not in allowlist"
    end
  end

  test "Actions.allowed_events/0 lists only existing gated events" do
    events = Actions.allowed_events() |> MapSet.to_list()
    assert "switch_tab" in events
    assert "run:start" in events
    refute "file:save" in events
    refute "tree:create" in events
  end

  ## Palette query / resolve

  test "query ranks file matches and respects limit", %{root: root} do
    items = Palette.query(root, "foo", limit: 3)
    assert is_list(items)
    assert Enum.all?(items, &match?(%Item{}, &1))
    assert length(items) <= 3
    assert Enum.any?(items, &(&1.kind == :file and &1.label == "lib/dev_ide/foo.ex"))
  end

  test "resolve maps file id back to a safe payload", %{root: root} do
    {:ok, payload} = Palette.resolve(root, "file:lib/bar.ex")
    assert payload.event == "annotation:open"
    assert payload.params == %{"path" => "lib/bar.ex"}
  end

  test "resolve refuses traversal in file id", %{root: root} do
    assert :error = Palette.resolve(root, "file:../etc/passwd")
  end

  test "resolve maps action ids to allowlisted events" do
    {:ok, %{event: "run:start", params: %{"id" => "test"}}} =
      Palette.resolve(nil, "command:test")

    {:ok, %{event: "switch_tab", params: %{"tab" => "files"}}} =
      Palette.resolve(nil, "tab:files")

    assert :error = Palette.resolve(nil, "command:rm-rf")
    assert :error = Palette.resolve(nil, "tab:nope")
  end

  test "resolve only emits events from the allowlist" do
    allowed = Actions.allowed_events()

    for item <- Actions.all() do
      assert item.payload.event in allowed, "leaked event: #{item.payload.event}"
    end
  end

  ## Terminal mode escalation actions

  test "Actions exposes raw/governed terminal mode entries" do
    ids =
      Actions.all()
      |> Enum.filter(&(&1.kind == :action))
      |> Enum.map(& &1.id)

    assert "action:terminal:raw" in ids
    assert "action:terminal:governed" in ids
  end

  test "terminal mode actions resolve to terminal:set_mode events" do
    {:ok, raw_payload} = Palette.resolve(nil, "action:terminal:raw")
    assert raw_payload.event == "terminal:set_mode"
    assert raw_payload.params == %{"mode" => "raw"}

    {:ok, gov_payload} = Palette.resolve(nil, "action:terminal:governed")
    assert gov_payload.event == "terminal:set_mode"
    assert gov_payload.params == %{"mode" => "governed"}
  end

  test "terminal:set_mode is on the allowed_events allowlist" do
    assert "terminal:set_mode" in Actions.allowed_events()
  end

  ## Tmux structural pane verbs

  test "Actions exposes structural tmux verbs under the :tmux category" do
    tmux = Actions.all() |> Enum.filter(&(Item.category(&1) == :tmux))
    ids = Enum.map(tmux, & &1.id)

    assert "tmux:find_pane" in ids
    assert "tmux:split_right" in ids
    assert "tmux:split_down" in ids
    assert "tmux:next_pane" in ids
    assert "tmux:previous_pane" in ids
    assert "tmux:zoom" in ids
    assert "tmux:cycle_layout" in ids
    assert "tmux:equalize" in ids
    assert "tmux:close_pane" in ids
    assert "tmux:close_other_panes" in ids
    # Terminal mode/chrome entries ride in the Tmux tab too.
    assert "action:terminal:raw" in ids
    assert "action:terminal:toggle_chrome" in ids
  end

  test "tmux verbs route only to param-less structural events (no send-keys)" do
    {:ok, %{event: "palette:find_pane", params: %{}}} = Palette.resolve(nil, "tmux:find_pane")
    {:ok, %{event: "split_right", params: %{}}} = Palette.resolve(nil, "tmux:split_right")
    {:ok, %{event: "split_down", params: %{}}} = Palette.resolve(nil, "tmux:split_down")
    {:ok, %{event: "pane:focus_next", params: %{}}} = Palette.resolve(nil, "tmux:next_pane")

    {:ok, %{event: "pane:focus_previous", params: %{}}} =
      Palette.resolve(nil, "tmux:previous_pane")

    {:ok, %{event: "pane:zoom_focused", params: %{}}} = Palette.resolve(nil, "tmux:zoom")
    {:ok, %{event: "pane:cycle_layout", params: %{}}} = Palette.resolve(nil, "tmux:cycle_layout")
    {:ok, %{event: "equalize_layout", params: %{}}} = Palette.resolve(nil, "tmux:equalize")
    {:ok, %{event: "pane:close_focused", params: %{}}} = Palette.resolve(nil, "tmux:close_pane")

    {:ok, %{event: "pane:close_others", params: %{}}} =
      Palette.resolve(nil, "tmux:close_other_panes")
  end

  test "new structural events are on the allowlist" do
    allowed = Actions.allowed_events()
    assert "palette:find_pane" in allowed
    assert "split_right" in allowed
    assert "split_down" in allowed
    assert "equalize_layout" in allowed
    assert "pane:close_focused" in allowed
    assert "pane:close_others" in allowed
    assert "pane:cycle_layout" in allowed
    assert "pane:focus_next" in allowed
    assert "pane:focus_previous" in allowed
    assert "pane:zoom_focused" in allowed
  end

  test "tmux verbs use tmux-palette compatible command labels" do
    by_id = Actions.all() |> Map.new(&{&1.id, &1.label})

    assert by_id["tmux:find_pane"] == "Find Pane"
    assert by_id["tmux:split_right"] == "Split Horizontal"
    assert by_id["tmux:split_down"] == "Split Vertical"
    assert by_id["tmux:next_pane"] == "Next Pane"
    assert by_id["tmux:previous_pane"] == "Previous Pane"
    assert by_id["tmux:zoom"] == "Zoom / Unzoom"
    assert by_id["tmux:cycle_layout"] == "Cycle Pane Layout"
    assert by_id["tmux:close_pane"] == "Close Pane"
    assert by_id["tmux:close_other_panes"] == "Close Other Panes"
  end

  ## Category filtering

  test "query scoped to :tmux returns only tmux items, no files", %{root: root} do
    items = Palette.query(root, "", category: :tmux, limit: 50)
    assert items != []
    assert Enum.all?(items, &(Item.category(&1) == :tmux))
    refute Enum.any?(items, &(&1.kind == :file))
  end

  test "query scoped to :commands returns only commands", %{root: root} do
    items = Palette.query(root, "", category: :commands, limit: 50)
    assert items != []
    assert Enum.all?(items, &(&1.kind == :command))
  end

  test "query scoped to :files returns only files", %{root: root} do
    items = Palette.query(root, "", category: :files, limit: 50)
    assert items != []
    assert Enum.all?(items, &(&1.kind == :file))
  end

  test "category :all is unfiltered (default)", %{root: root} do
    all = Palette.query(root, "", limit: 200)
    explicit_all = Palette.query(root, "", category: :all, limit: 200)
    assert length(all) == length(explicit_all)
    kinds = all |> Enum.map(& &1.kind) |> Enum.uniq()
    assert :file in kinds
    assert :command in kinds
  end

  ## Item.category derivation

  test "Item.category derives from kind and honors explicit category" do
    assert Item.category(%Item{id: "f", kind: :file, label: "x"}) == :files
    assert Item.category(%Item{id: "c", kind: :command, label: "x"}) == :commands
    assert Item.category(%Item{id: "t", kind: :tab, label: "x"}) == :actions
    assert Item.category(%Item{id: "a", kind: :action, label: "x"}) == :actions

    assert Item.category(%Item{id: "a", kind: :action, label: "x", category: :tmux}) == :tmux
  end
end
