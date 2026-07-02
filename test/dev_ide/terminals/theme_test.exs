defmodule DevIDE.Terminals.ThemeTest do
  # Serial: mutates process-global Application env (:terminal_theme_paths).
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals.Theme

  describe "defaults" do
    test "exposes the startup scheme and preset" do
      assert Theme.default_scheme() == :dark
      assert Theme.default_preset_id() == "catppuccin"
    end
  end

  describe "parse_conf/1" do
    test "parses ghostty-style colors and palette entries" do
      conf = """
      # theme
      background = #1e1e2e
      foreground = #cdd6f4
      cursor-color = #f5e0dc
      palette = 1=#f38ba8
      palette = 4=#89b4fa
      """

      parsed = Theme.parse_conf(conf)

      assert parsed[:background] == {30, 30, 46}
      assert parsed[:foreground] == {205, 214, 244}
      assert parsed[:cursor_color] == "#f5e0dc"
      assert parsed[:palette][1] == {243, 139, 168}
      assert parsed[:palette][4] == {137, 180, 250}
    end
  end

  describe "rewrite_pty_write/2" do
    test "replaces OSC 10/11/12 and palette responses" do
      theme = Theme.builtin_preset(:dark, "catppuccin")

      input =
        [
          "\e]10;rgb:ffff/ffff/ffff\a",
          "\e]11;#000000\a",
          "\e]12;#ffffff\a",
          "\e]4;1;rgb:ff00/0000/0000\a"
        ]
        |> IO.iodata_to_binary()

      output = Theme.rewrite_pty_write(input, theme)

      # XTerm-canonical replies: rgb:rrrr/gggg/bbbb with hex-doubled channels.
      assert output =~ "\e]10;rgb:cdcd/d6d6/f4f4\a"
      assert output =~ "\e]11;rgb:1e1e/1e1e/2e2e\a"
      assert output =~ "\e]12;rgb:f5f5/e0e0/dcdc\a"
      assert output =~ "\e]4;1;rgb:f3f3/8b8b/a8a8\a"
    end

    test "leaves unrelated bytes untouched" do
      theme = Theme.builtin_preset(:light, "catppuccin")
      assert Theme.rewrite_pty_write("hello\n", theme) == "hello\n"
    end
  end

  describe "client_bundle/1" do
    test "returns serializable dark and light presets" do
      bundle = Theme.client_bundle("catppuccin")

      assert bundle.preset == "catppuccin"
      assert bundle.dark.id == "catppuccin_mocha"
      assert bundle.light.id == "catppuccin_latte"
      assert length(bundle.dark.palette) == 256
      assert length(bundle.light.palette) == 256
      assert Enum.all?(bundle.dark.palette, &match?([_, _, _], &1))
    end

    test "zinc preset uses baseline LUT" do
      dark = Theme.load_for_scheme(:dark, "zinc")
      assert dark.id == "zinc"
      assert Enum.at(dark.palette, 1) == {128, 0, 0}
    end

    test "list_presets includes built-ins plus system import" do
      ids = Theme.list_presets() |> Enum.map(& &1.id)
      assert length(ids) == 12
      assert "gruvbox" in ids
      assert "tokyo_night" in ids
      assert "system" in ids
    end
  end

  describe "merge via load_for_scheme/1" do
    test "merges a temp ghostty.conf over the preset" do
      path = Path.join(System.tmp_dir!(), "devide-theme-test-#{System.unique_integer()}.conf")

      content = """
      background = #101010
      foreground = #eeeeee
      palette = 2 = #00ff00
      """

      prev = Application.get_env(:dev_ide, :terminal_theme_paths)

      try do
        File.write!(path, content)
        Application.put_env(:dev_ide, :terminal_theme_paths, %{dark: [path], light: [path]})

        theme = Theme.load_for_scheme(:dark, "system")

        assert theme.chrome["--devide-term-bg"] == "#101010"
        assert theme.chrome["--devide-term-fg"] == "#eeeeee"
        assert Enum.at(theme.palette, 2) == {0, 255, 0}
      after
        case prev do
          nil -> Application.delete_env(:dev_ide, :terminal_theme_paths)
          value -> Application.put_env(:dev_ide, :terminal_theme_paths, value)
        end

        File.rm(path)
      end
    end
  end
end
