defmodule DevIDE.Elixir.SymbolsTest do
  use ExUnit.Case, async: true
  alias DevIDE.Elixir.Symbols

  test "extracts module + public/private functions with arity" do
    src = """
    defmodule Foo.Bar do
      def hello, do: :ok
      def add(a, b), do: a + b
      defp helper(_x), do: :ok
      def with_default(opts \\\\ []), do: opts
    end
    """

    s = Symbols.extract(src, "lib/foo/bar.ex")
    by_name = Map.new(s, &{&1.name, &1})

    assert by_name["Foo.Bar"].kind == :module
    assert by_name["hello/0"].arity == 0
    assert by_name["hello/0"].visibility == :public
    assert by_name["add/2"].arity == 2
    assert by_name["helper/1"].visibility == :private
    assert by_name["with_default/1"].arity == 1
  end

  test "captures defmacro/defguard/defdelegate" do
    src = """
    defmodule M do
      defmacro mac(x), do: x
      defmacrop priv_mac(x), do: x
      defguard is_thing(x) when is_integer(x)
      defdelegate other(a, b), to: Other
    end
    """

    names = Symbols.extract(src, "lib/m.ex") |> Enum.map(& &1.name) |> MapSet.new()

    assert MapSet.member?(names, "mac/1")
    assert MapSet.member?(names, "priv_mac/1")
    assert MapSet.member?(names, "is_thing/1")
    assert MapSet.member?(names, "other/2")
  end

  test "captures describe/test in *_test.exs files" do
    src = """
    defmodule FooTest do
      use ExUnit.Case
      describe "thing" do
        test "works" do
          assert true
        end
      end
      test "isolated" do
        assert true
      end
    end
    """

    s = Symbols.extract(src, "test/foo_test.exs")
    kinds = Enum.map(s, & &1.kind)
    names = Enum.map(s, & &1.name)

    assert :describe in kinds
    assert :test in kinds
    assert "thing" in names
    assert "works" in names
    assert "isolated" in names
  end

  test "non-elixir file returns []" do
    assert [] = Symbols.extract("# README\nhello\n", "README.md")
  end

  test "unmatched lines do not produce symbols" do
    assert [] = Symbols.extract("just a comment\nfoo bar\n", "lib/x.ex")
  end

  test "arity counts only top-level commas" do
    src = """
    defmodule M do
      def f(a, {b, c}, [d, e]), do: :ok
    end
    """

    s = Symbols.extract(src, "lib/m.ex")
    assert Enum.find(s, &(&1.kind == :function)).arity == 3
  end
end
