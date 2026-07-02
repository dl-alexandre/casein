defmodule DevIDE.Links.MarkdownTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Links.Markdown
  alias DevIDE.Links.Resolver.Ctx
  alias DevIDE.Workspace

  test "renders sanitized markdown and rewrites verified workspace file links" do
    root = tmp_root!()
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "docs/img"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "docs/pic.png"), "png")
    File.write!(Path.join(root, "docs/img/shot.png"), "png")
    File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo, do: :ok")

    workspace = %Workspace{
      id: "ws one",
      name: "ws one",
      user: "owner",
      path: root,
      metadata: %{attached_folder: true}
    }

    ctx = %Ctx{
      workspace: workspace,
      base_dir: Path.join(root, "docs"),
      source: :doc
    }

    markdown = """
    # Intro

    ![pic](pic.png)
    [![shot](img/shot.png)](img/shot.png)
    [code](../lib/foo.ex)
    [missing](missing.txt)
    [local](#intro)
    [bad](javascript:alert(1))
    <script>alert(1)</script>
    """

    assert {:ok, html} = Markdown.render_html(markdown, ctx)

    assert html =~ ~s(src="/api/workspaces/ws%20one/files/docs/pic.png")
    assert html =~ ~s(href="/api/workspaces/ws%20one/files/lib/foo.ex")

    assert html |> String.split("/api/workspaces/ws%20one/files/docs/img/shot.png") |> length() ==
             3

    assert html =~ ~s(href="missing.txt")
    assert html =~ ~s(href="#intro")
    refute html =~ "javascript:"
    refute html =~ "<script"
  end

  test "keeps markdown anchors when building workspace file URLs" do
    workspace = %Workspace{id: "ws", name: "ws"}

    assert Markdown.file_url(workspace, "docs/README.md", "Hello There!") ==
             "/api/workspaces/ws/files/docs/README.md#Hello%20There%21"
  end

  defp tmp_root! do
    root =
      Path.join(System.tmp_dir!(), "markdown-render-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    root
  end
end
