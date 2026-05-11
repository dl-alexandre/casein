defmodule DevIDE.Commands.AnnotationsTest do
  use ExUnit.Case, async: true

  alias DevIDE.Commands.Annotations
  alias DevIDE.Commands.Annotations.MixParser

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ann-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    _ = File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join([root, "lib", "foo.ex"]), "")
    File.write!(Path.join([root, "test", "foo_test.exs"]), "")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "compile error single-line", %{root: root} do
    out = "** (CompileError) lib/foo.ex:34:5: undefined variable\n"
    [a] = MixParser.parse(out, "compile", root)
    assert a.kind == :compile_error
    assert a.severity == :error
    assert a.file == "lib/foo.ex"
    assert a.line == 34
    assert a.column == 5
    refute a.stale
  end

  test "compile warning followed by file:line reference", %{root: root} do
    out = """
    warning: variable "x" is unused
        │
     12 │ x = 1
        │ ~
        │
        └─ lib/foo.ex:12:5: Foo.fn/0
    """

    [a] = MixParser.parse(out, "compile", root)
    assert a.kind == :compile_warning
    assert a.severity == :warning
    assert a.file == "lib/foo.ex"
    assert a.line == 12
    assert a.column == 5
    assert a.message =~ "unused"
  end

  test "test failure file:line", %{root: root} do
    out = """
      1) test it works (FooTest)
         test/foo_test.exs:27
         Assertion with == failed
    """

    [a] = MixParser.parse(out, "test", root)
    assert a.kind == :test_failure
    assert a.severity == :error
    assert a.file == "test/foo_test.exs"
    assert a.line == 27
  end

  test "formatter --check-formatted lists files", %{root: root} do
    out = """
    mix format failed due to --check-formatted.
    The following files are not formatted:
      lib/foo.ex
    """

    [a] = MixParser.parse(out, "format", root)
    assert a.kind == :formatter
    assert a.file == "lib/foo.ex"
    assert is_nil(a.line)
    assert a.message =~ "needs formatting"
  end

  test "path traversal in annotation is dropped", %{root: root} do
    out = "** (CompileError) ../../etc/passwd:1: nope\n"
    assert [] = MixParser.parse(out, "compile", root)
  end

  test "missing file is marked stale, not dropped", %{root: root} do
    out = "** (CompileError) lib/missing.ex:1: oops\n"
    [a] = MixParser.parse(out, "compile", root)
    assert a.stale
    assert a.file == "lib/missing.ex"
  end

  test "from_record splits by severity", %{root: root} do
    out = """
    warning: x
        └─ lib/foo.ex:1: Foo.f/0
    ** (CompileError) lib/foo.ex:5: bad
    """

    record = %{output: out, command_id: "compile"}
    anns = Annotations.from_record(record, root)
    grouped = Annotations.group_by_severity(anns)
    assert length(grouped.error) == 1
    assert length(grouped.warning) == 1
  end

  test "empty/nil output yields []", %{root: root} do
    assert MixParser.parse("", "compile", root) == []
    assert MixParser.parse(nil, "compile", root) == []
    assert Annotations.from_record(%{output: nil, command_id: "test"}, root) == []
  end

  test "annotations are de-duplicated by (kind, file, line, col, message)", %{root: root} do
    out = """
    ** (CompileError) lib/foo.ex:1: oops
    ** (CompileError) lib/foo.ex:1: oops
    """

    assert length(MixParser.parse(out, "compile", root)) == 1
  end
end
