defmodule DevIDE.Terminals.ClipboardPasteTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.ClipboardPaste

  setup do
    root =
      Path.join(System.tmp_dir!(), "devide-clipboard-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  test "saves a base64 image under .devide clipboard directory", %{root: root} do
    data = Base.encode64("png bytes")

    assert {:ok, result} =
             ClipboardPaste.save_image(root, %{
               "name" => "Screen Shot 2026/06/04.png",
               "type" => "image/png",
               "data" => data
             })

    assert result.bytes == byte_size("png bytes")
    assert result.content_type == "image/png"
    assert result.relative_path =~ ~r|^\.devide/clipboard/|
    assert result.path == Path.join(root, result.relative_path)
    assert File.read!(result.path) == "png bytes"
    assert Path.extname(result.path) == ".png"
  end

  test "accepts data URLs", %{root: root} do
    data = "data:image/jpeg;base64," <> Base.encode64("jpg bytes")

    assert {:ok, result} =
             ClipboardPaste.save_image(root, %{
               "name" => "photo.jpeg",
               "type" => "image/jpeg",
               "data" => data
             })

    assert File.read!(result.path) == "jpg bytes"
    assert Path.extname(result.path) == ".jpeg"
  end

  test "rejects unsupported image types", %{root: root} do
    assert {:error, :unsupported_type} =
             ClipboardPaste.save_image(root, %{
               "name" => "vector.svg",
               "type" => "image/svg+xml",
               "data" => Base.encode64("<svg></svg>")
             })
  end

  test "saves arbitrary dropped files with sanitized names", %{root: root} do
    assert {:ok, result} =
             ClipboardPaste.save_file(root, %{
               "name" => "../../notes from drag.txt",
               "type" => "text/plain",
               "data" => Base.encode64("hello")
             })

    assert result.content_type == "text/plain"
    assert result.relative_path =~ ~r|^\.devide/clipboard/|
    assert result.relative_path =~ "notes-from-drag.txt"
    assert File.read!(result.path) == "hello"
    assert Path.dirname(result.path) == Path.join(root, ".devide/clipboard")
  end

  test "excludes clipboard handoff files from local git status", %{root: root} do
    init_git!(root)

    for name <- ["one.png", "two.png"] do
      assert {:ok, _result} =
               ClipboardPaste.save_image(root, %{
                 "name" => name,
                 "type" => "image/png",
                 "data" => Base.encode64("png bytes")
               })
    end

    assert git_status!(root) == ""

    exclude = File.read!(git_path!(root, "info/exclude"))

    assert exclude
           |> String.split("\n")
           |> Enum.count(&(String.trim(&1) == ".devide/clipboard/")) == 1
  end

  test "excludes clipboard handoff files from a git subdirectory workspace", %{root: root} do
    repo_root = Path.join(root, "repo")
    workspace_root = Path.join(repo_root, "nested")
    File.mkdir_p!(workspace_root)
    init_git!(repo_root)

    assert {:ok, _result} =
             ClipboardPaste.save_image(workspace_root, %{
               "name" => "screen.png",
               "type" => "image/png",
               "data" => Base.encode64("png bytes")
             })

    assert git_status!(repo_root) == ""

    exclude = File.read!(git_path!(workspace_root, "info/exclude"))
    assert exclude =~ "nested/.devide/clipboard/"
  end

  test "adds an image extension when clipboard image name has none", %{root: root} do
    assert {:ok, result} =
             ClipboardPaste.save_file(root, %{
               "name" => "clipboard-image",
               "type" => "image/webp",
               "data" => Base.encode64("webp")
             })

    assert Path.extname(result.path) == ".webp"
  end

  test "rejects invalid base64", %{root: root} do
    assert {:error, :invalid_base64} =
             ClipboardPaste.save_image(root, %{
               "name" => "bad.png",
               "type" => "image/png",
               "data" => "not base64"
             })
  end

  test "rejects oversized images", %{root: root} do
    data = Base.encode64(:binary.copy(<<0>>, ClipboardPaste.max_image_bytes() + 1))

    assert {:error, :too_large} =
             ClipboardPaste.save_image(root, %{
               "name" => "large.png",
               "type" => "image/png",
               "data" => data
             })
  end

  defp init_git!(root) do
    {_, 0} =
      System.cmd("git", ["-C", root, "init", "--initial-branch=main"], stderr_to_stdout: true)

    :ok
  end

  defp git_status!(root) do
    {out, 0} =
      System.cmd("git", ["-C", root, "status", "--short", "--untracked-files=all"],
        stderr_to_stdout: true
      )

    out
  end

  defp git_path!(root, path) do
    {out, 0} = System.cmd("git", ["-C", root, "rev-parse", "--git-path", path])
    path = String.trim(out)

    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end
end
