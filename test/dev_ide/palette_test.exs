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
end
