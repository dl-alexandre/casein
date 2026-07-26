defmodule Casein.Terminals.ToolThemesTest do
  use Casein.TestCase, async: false

  import ExUnit.CaptureLog

  alias Casein.Terminals.{Shims, ToolThemes}

  @stale {{2020, 1, 1}, {0, 0, 0}}

  setup do
    previous_home = Application.get_env(:casein, :tool_theme_home)
    previous_enabled = Application.get_env(:casein, :tool_themes_enabled)

    home =
      Path.join(System.tmp_dir!(), "casein-tool-themes-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    Application.put_env(:casein, :tool_theme_home, home)
    Application.put_env(:casein, :tool_themes_enabled, true)
    ToolThemes.reset_memo!()

    on_exit(fn ->
      restore(:tool_theme_home, previous_home)
      restore(:tool_themes_enabled, previous_enabled)
      ToolThemes.reset_memo!()
      File.chmod(home, 0o755)
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  describe "static mode (elio)" do
    test "creates the theme file with the marker as line 1", %{home: home} do
      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)

      path = elio_path(home)
      content = File.read!(path)
      assert content |> String.split("\n", parts: 2) |> hd() == ToolThemes.marker()
      assert content =~ "[palette]"
      assert content == elio_desired_content()
    end

    test "second call is a no-op", %{home: home} do
      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)
      path = elio_path(home)
      File.touch!(path, @stale)

      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)
      assert File.stat!(path, time: :universal).mtime == @stale
    end

    test "restores same-size drift landing within the mtime granularity", %{home: home} do
      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)
      path = elio_path(home)
      %File.Stat{mtime: mtime} = File.stat!(path, time: :universal)

      # Same byte size, same mtime: invisible to a stat fingerprint, only the
      # content hash can tell the file drifted.
      desired = elio_desired_content()
      drifted = binary_part(desired, 0, byte_size(desired) - 2) <> "X\n"
      File.write!(path, drifted)
      File.touch!(path, mtime)

      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)
      assert File.read!(path) == desired
    end

    test "restores a drifted marker-carrying file", %{home: home} do
      path = elio_path(home)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, ToolThemes.marker() <> "\ntext = \"ansi-red\"\n")

      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)
      assert File.read!(path) == elio_desired_content()
    end

    test "restores a marker-carrying file that drifts after a memoized success", %{home: home} do
      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)
      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)

      path = elio_path(home)
      File.write!(path, ToolThemes.marker() <> "\ntext = \"ansi-red\"\n")
      File.touch!(path, @stale)

      assert :ok = ToolThemes.ensure("elio", elio_spec(), :dark)
      assert File.read!(path) == elio_desired_content()
    end

    test "never touches a marker-less file", %{home: home} do
      path = elio_path(home)
      File.mkdir_p!(Path.dirname(path))
      user_content = "[palette]\ntext = \"ansi-red\"\n"
      File.write!(path, user_content)

      assert {:skipped, :user_managed} = ToolThemes.ensure("elio", elio_spec(), :dark)
      assert {:skipped, :user_managed} = ToolThemes.ensure("elio", elio_spec(), :dark)
      assert File.read!(path) == user_content
    end
  end

  describe "scheme_variant mode (grok)" do
    test "does not stamp while draining", %{home: home} do
      Casein.Deployment.Drain.reset_for_test!()
      on_exit(fn -> Casein.Deployment.Drain.reset_for_test!() end)
      assert :ok = Casein.Deployment.Drain.start_drain(0)

      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)
      refute File.exists?(grok_path(home))
    end

    test "creates a fresh file with just the stamped section", %{home: home} do
      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)
      assert File.read!(grok_path(home)) == "[ui]\ntheme = \"groknight\"\n"
    end

    # ~/.grok/config.toml is shared by every workspace on the box and grok
    # hot-reloads it, so whatever the light scheme stamps lands on every
    # running grok pane. grokday is banned: it renders illegibly in the
    # Casein viewer.
    test "light scheme stamps tokyonight, never grokday", %{home: home} do
      assert :ok = ToolThemes.ensure("grok", grok_spec(), :light)
      assert File.read!(grok_path(home)) == "[ui]\ntheme = \"tokyonight\"\n"
    end

    test "replaces an existing theme key in [ui]", %{home: home} do
      path = grok_path(home)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[ui]\ntheme = \"custom\"\n")

      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)
      assert File.read!(path) == "[ui]\ntheme = \"groknight\"\n"
    end

    test "inserts the key after the section header when [ui] lacks it", %{home: home} do
      path = grok_path(home)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[ui]\nscroll = true\n")

      assert :ok = ToolThemes.ensure("grok", grok_spec(), :light)
      assert File.read!(path) == "[ui]\ntheme = \"tokyonight\"\nscroll = true\n"
    end

    test "appends a [ui] section when the file has none", %{home: home} do
      path = grok_path(home)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[mcp_servers.casein]\nurl = \"https://example.test\"\n")

      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)

      assert File.read!(path) ==
               "[mcp_servers.casein]\nurl = \"https://example.test\"\n\n[ui]\ntheme = \"groknight\"\n"
    end

    test "second call with the same scheme does not rewrite the file", %{home: home} do
      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)
      path = grok_path(home)
      File.touch!(path, @stale)

      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)
      assert File.stat!(path, time: :universal).mtime == @stale
    end

    test "re-stamps a hand-edited theme after a memoized success", %{home: home} do
      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)
      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)

      path = grok_path(home)
      File.write!(path, "[ui]\ntheme = \"hand-edited\"\nscroll = true\n")
      File.touch!(path, @stale)

      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)
      assert File.read!(path) == "[ui]\ntheme = \"groknight\"\nscroll = true\n"
    end

    test "preserves unrelated content byte-for-byte", %{home: home} do
      path = grok_path(home)
      File.mkdir_p!(Path.dirname(path))

      existing =
        """
        # hand-written header

        [mcp_servers.casein]
        url = "https://example.test"   # trailing comment

        [ui]
        # keep this comment
        theme   =   "custom"
        scroll = true

        [tail]
        a = 1
        """

      File.write!(path, existing)

      assert :ok = ToolThemes.ensure("grok", grok_spec(), :dark)

      assert File.read!(path) ==
               String.replace(existing, "theme   =   \"custom\"", "theme = \"groknight\"")
    end
  end

  describe "ensure_all/1" do
    test "provisions every registry-declared tool theme", %{home: home} do
      assert :ok = ToolThemes.ensure_all(:light)

      assert File.read!(elio_path(home)) == elio_desired_content()
      assert File.read!(grok_path(home)) == "[ui]\ntheme = \"tokyonight\"\n"
    end

    test "never raises with an unwritable home" do
      locked =
        Path.join(
          System.tmp_dir!(),
          "casein-tool-themes-ro-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(locked)
      File.chmod!(locked, 0o500)

      on_exit(fn ->
        File.chmod(locked, 0o755)
        File.rm_rf(locked)
      end)

      Application.put_env(:casein, :tool_theme_home, locked)

      log =
        capture_log(fn ->
          assert :ok = ToolThemes.ensure_all(:dark)
        end)

      assert log =~ "tool theme provisioning failed"
    end

    test "is a no-op when :tool_themes_enabled is false", %{home: home} do
      Application.put_env(:casein, :tool_themes_enabled, false)

      assert :ok = ToolThemes.ensure_all(:dark)
      refute File.exists?(Path.join(home, ".config"))
      refute File.exists?(Path.join(home, ".grok"))
    end
  end

  defp elio_spec, do: Map.fetch!(Shims.theme_specs(), "elio")
  defp grok_spec, do: Map.fetch!(Shims.theme_specs(), "grok")

  defp elio_path(home), do: Path.join(home, ".config/elio/theme.toml")
  defp grok_path(home), do: Path.join(home, ".grok/config.toml")

  defp elio_desired_content do
    template =
      :casein
      |> :code.priv_dir()
      |> Path.join("tool_themes/elio/theme.toml")
      |> File.read!()

    assert template |> String.split("\n", parts: 2) |> hd() == ToolThemes.marker()
    template
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
