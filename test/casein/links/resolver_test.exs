defmodule Casein.Links.ResolverTest do
  use Casein.TestCase, async: true

  alias Casein.Links.Resolver
  alias Casein.Links.Resolver.Ctx
  alias Casein.Links.Scanner

  setup do
    root = Path.join(System.tmp_dir!(), "links-resolver-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo do\nend\n")
    File.write!(Path.join(root, "docs/readme.md"), "# Heading\n")

    on_exit(fn -> File.rm_rf(root) end)

    workspace = %Casein.Workspace{
      id: "links-resolver",
      name: "links-resolver",
      path: root,
      metadata: %{attached_folder: true, detected_ports: [49_321]}
    }

    {:ok, root: root, workspace: workspace}
  end

  test "resolves a relative file with line and column from cwd", %{root: root, workspace: ws} do
    ctx = %Ctx{workspace: ws, base_dir: Path.join(root, "lib")}

    assert {:ok, {:file, %{path: "lib/foo.ex", line: 12, col: 5}}} =
             Resolver.resolve("foo.ex:12:5", ctx)
  end

  test "falls back to workspace root when cwd-relative path misses", %{root: root, workspace: ws} do
    ctx = %Ctx{workspace: ws, base_dir: Path.join(root, "test")}

    assert {:ok, {:file, %{path: "lib/foo.ex", line: 12, col: nil}}} =
             Resolver.resolve("lib/foo.ex:12", ctx)
  end

  test "resolves file URIs with an authority as host path references", %{
    root: root,
    workspace: ws
  } do
    ctx = %Ctx{workspace: ws}
    target = "file://devbox#{Path.join(root, "lib/foo.ex")}:7"

    assert {:ok, {:file, %{path: "lib/foo.ex", line: 7}}} = Resolver.resolve(target, ctx)
  end

  test "scanner-trimmed punctuation resolves cleanly", %{workspace: ws} do
    [%{raw: raw}] = Scanner.scan_row("(see lib/foo.ex:3)")

    assert {:ok, {:file, %{path: "lib/foo.ex", line: 3}}} =
             Resolver.resolve(raw, %Ctx{workspace: ws})
  end

  test "verifies detected localhost ports and skips undetected ports", %{workspace: ws} do
    ctx = %Ctx{workspace: ws}

    assert {:ok, {:localhost, %{url: "http://localhost:49321/x", port: 49_321}}} =
             Resolver.resolve("http://127.0.0.1:49321/x", ctx)

    assert :skip = Resolver.resolve("http://localhost:49322/x", ctx)
  end

  test "classifies non-loopback http URLs as external", %{workspace: ws} do
    assert {:ok, {:external, %{url: "https://example.com/docs"}}} =
             Resolver.resolve("https://example.com/docs", %Ctx{workspace: ws})
  end

  test "carries markdown anchors", %{workspace: ws} do
    assert {:ok, {:markdown, %{path: "docs/readme.md", anchor: "heading"}}} =
             Resolver.resolve("docs/readme.md#heading", %Ctx{workspace: ws})
  end

  test "rejects traversal outside the workspace root", %{root: root, workspace: ws} do
    ctx = %Ctx{workspace: ws, base_dir: Path.join(root, "lib")}

    assert {:error, :outside_root} = Resolver.resolve("../../etc/passwd", ctx)
  end

  test "rejects non-allowlisted URI schemes", %{workspace: ws} do
    assert {:error, :scheme_not_allowed} =
             Resolver.resolve("javascript:alert(1)", %Ctx{workspace: ws})
  end

  test "skips missing files", %{workspace: ws} do
    assert :skip = Resolver.resolve("lib/missing.ex", %Ctx{workspace: ws})
  end

  test "skips cwd-relative missing paths when root fallback would escape", %{
    root: root,
    workspace: ws
  } do
    ctx = %Ctx{workspace: ws, base_dir: Path.join(root, "lib")}

    assert :skip = Resolver.resolve("../missing.ex", ctx)
  end
end
