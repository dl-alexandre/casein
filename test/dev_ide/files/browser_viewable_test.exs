defmodule DevIDE.Files.BrowserViewableTest do
  use ExUnit.Case, async: true

  alias DevIDE.Files.BrowserViewable

  describe "surface/1" do
    test "routes browser-native types to :preview" do
      for path <- ~w(
        report.html index.htm diagram.svg report.pdf
        shot.png photo.jpg photo.jpeg anim.gif hero.webp hero.avif icon.bmp favicon.ico
        docs/nested/photo.PNG
      ) do
        assert BrowserViewable.surface(path) == :preview, "expected :preview for #{path}"
      end
    end

    test "routes source and other types to :file" do
      for path <- ~w(
        lib/foo.ex README.md package.json notes.txt style.css app.js data.bin
      ) do
        assert BrowserViewable.surface(path) == :file, "expected :file for #{path}"
      end
    end
  end

  describe "content_type/1" do
    test "returns real MIME types for browser-viewable extensions" do
      assert BrowserViewable.content_type("a.html") == "text/html"
      assert BrowserViewable.content_type("a.htm") == "text/html"
      assert BrowserViewable.content_type("a.svg") == "image/svg+xml"
      assert BrowserViewable.content_type("a.pdf") == "application/pdf"
      assert BrowserViewable.content_type("a.png") == "image/png"
      assert BrowserViewable.content_type("a.jpg") == "image/jpeg"
      assert BrowserViewable.content_type("a.jpeg") == "image/jpeg"
      assert BrowserViewable.content_type("a.gif") == "image/gif"
      assert BrowserViewable.content_type("a.webp") == "image/webp"
      assert BrowserViewable.content_type("a.avif") == "image/avif"
      assert BrowserViewable.content_type("a.bmp") == "image/bmp"
      assert BrowserViewable.content_type("a.ico") == "image/x-icon"
    end

    test "falls back to application/octet-stream" do
      assert BrowserViewable.content_type("lib/foo.ex") == "application/octet-stream"
      assert BrowserViewable.content_type("noext") == "application/octet-stream"
    end
  end

  describe "other/1" do
    test "flips :file and :preview" do
      assert BrowserViewable.other(:file) == :preview
      assert BrowserViewable.other(:preview) == :file
    end
  end
end
