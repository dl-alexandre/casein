defmodule CaseinMob.ThemeTest do
  use ExUnit.Case, async: false

  alias CaseinMob.Theme

  test "dark brand theme is indigo primary on blue-tinted near-black surfaces" do
    theme = Theme.dark()

    assert theme.primary == 0xFF605DFF
    assert theme.background == 0xFF13171C
    assert theme.surface == 0xFF1A1F26
    assert theme.on_surface == 0xFFE6EDF5
  end

  test "light brand theme keeps the same brand hues on inverted surfaces" do
    theme = Theme.light()

    assert theme.primary == 0xFF4F46E5
    assert theme.background == 0xFFF5F7FA
    assert theme.surface == 0xFFFFFFFF
    assert theme.on_surface == 0xFF11161C
  end

  test "theme/0 is the dark brand default used by Mob.App" do
    assert Theme.theme() == Theme.dark()
  end

  test "Mob.Theme.set/1 accepts the brand theme modules' built structs" do
    assert :ok = Mob.Theme.set(Theme.dark())
    assert Mob.Theme.current().primary == 0xFF605DFF

    assert :ok = Mob.Theme.set(Theme.light())
    assert Mob.Theme.current().primary == 0xFF4F46E5
  end

  test "stock Hex mob_themes is not a dependency or default style" do
    lock = Mix.Dep.Lock.read()
    mob_config = Config.Reader.read!(Path.expand("../../mob.exs", __DIR__))[:mob] || []

    refute Map.has_key?(lock, :mob_themes)
    assert Keyword.get(mob_config, :styles, :missing) == []
    assert Keyword.get(mob_config, :default_style) == nil
  end
end
