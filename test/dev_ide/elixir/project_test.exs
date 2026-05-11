defmodule DevIDE.Elixir.ProjectTest do
  use ExUnit.Case, async: true
  alias DevIDE.Elixir.{Project, Tooling}

  setup do
    root = Path.join(System.tmp_dir!(), "proj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "bare directory returns mostly false flags", %{root: root} do
    p = Project.detect(root)
    refute p.mix?
    refute p.phoenix?
    refute p.live_view?
    refute p.ecto?
    refute p.umbrella?
    refute p.formatter?
  end

  test "Phoenix + LiveView + Ecto detected from mix.exs", %{root: root} do
    File.write!(Path.join(root, "mix.exs"), """
    defmodule Foo.MixProject do
      def project, do: []
      defp deps, do: [
        {:phoenix, "~> 1.8"},
        {:phoenix_live_view, "~> 1.0"},
        {:ecto_sql, "~> 3.13"}
      ]
    end
    """)

    File.write!(Path.join(root, ".formatter.exs"), "[]\n")

    p = Project.detect(root)
    assert p.mix?
    assert p.phoenix?
    assert p.live_view?
    assert p.ecto?
    assert p.formatter?
  end

  test "umbrella detected when apps/*/mix.exs exists", %{root: root} do
    File.mkdir_p!(Path.join([root, "apps", "core"]))

    File.write!(
      Path.join([root, "apps", "core", "mix.exs"]),
      "defmodule Core.MixProject do\nend\n"
    )

    p = Project.detect(root)
    assert p.umbrella?
  end

  test "umbrella ignores deps/_build under apps", %{root: root} do
    File.mkdir_p!(Path.join([root, "apps", "_build", "lib"]))
    File.write!(Path.join([root, "apps", "_build", "mix.exs"]), "")
    p = Project.detect(root)
    refute p.umbrella?
  end

  test "tooling detection finds .formatter.exs and lock entries", %{root: root} do
    File.write!(Path.join(root, ".formatter.exs"), "[]\n")

    File.write!(
      Path.join(root, "mix.lock"),
      ~s|%{"lexical": {:hex, :lexical, "0.1.0", [], [], "hexpm"}}|
    )

    t = Tooling.detect(root)
    assert t.formatter?
    assert t.mix_lock_lexical?
    refute t.mix_lock_elixir_ls?
  end
end
