defmodule DevIDE.Terminals.ShimsTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals.Shims

  setup do
    previous_dir = Application.get_env(:dev_ide, :terminal_shims_dir)
    previous_tool_root = Application.get_env(:dev_ide, :terminal_tools_dir)
    tmp = Path.join(System.tmp_dir!(), "devide-shims-test-#{System.unique_integer([:positive])}")
    shim_dir = Path.join(tmp, "shims")
    tool_root = Path.join(tmp, "tools")
    real_dir = Path.join(tmp, "real")
    clean_bin = Path.join(tmp, "bin")

    Application.put_env(:dev_ide, :terminal_shims_dir, shim_dir)
    Application.put_env(:dev_ide, :terminal_tools_dir, tool_root)
    File.mkdir_p!(real_dir)
    write_clean_bin!(clean_bin)

    on_exit(fn ->
      restore(:terminal_shims_dir, previous_dir)
      restore(:terminal_tools_dir, previous_tool_root)
      File.rm_rf(tmp)
    end)

    {:ok, shim_dir: shim_dir, tool_root: tool_root, real_dir: real_dir, clean_bin: clean_bin}
  end

  test "materializes an elio shim that enables OSC52 lazily", %{
    shim_dir: shim_dir,
    real_dir: real_dir
  } do
    write_fake_elio!(real_dir)

    assert :ok = Shims.materialize!()
    shim = Shims.shim_path("elio")
    assert File.regular?(shim)
    assert File.regular?(Shims.install_script_path("elio"))

    {out, 0} =
      System.cmd(shim, [],
        env: [{"PATH", Enum.join([shim_dir, real_dir, "/usr/bin", "/bin"], ":")}],
        stderr_to_stdout: true
      )

    assert out =~ "ELIO_CLIPBOARD_OSC52=1"
    assert out =~ "DEV_IDE_APP_SHIM=elio"
    assert out =~ "DEV_IDE_TERMINAL=1"
    assert out =~ "DEV_IDE_CLIPBOARD=osc52"
  end

  test "materialize! skips rewriting files that already match" do
    assert :ok = Shims.materialize!()
    shim = Shims.shim_path("elio")
    install = Shims.install_script_path("elio")

    stale = {{2020, 1, 1}, {0, 0, 0}}
    File.touch!(shim, stale)
    File.touch!(install, stale)

    assert :ok = Shims.materialize!()

    assert File.stat!(shim, time: :universal).mtime == stale
    assert File.stat!(install, time: :universal).mtime == stale
  end

  test "materialize! restores a drifted shim" do
    assert :ok = Shims.materialize!()
    shim = Shims.shim_path("elio")
    expected = File.read!(shim)

    File.write!(shim, "#!/bin/bash\necho corrupted\n")
    assert :ok = Shims.materialize!()
    assert File.read!(shim) == expected
  end

  test "materialize! restores a shim with drifted permissions" do
    assert :ok = Shims.materialize!()
    shim = Shims.shim_path("elio")
    File.chmod!(shim, 0o644)

    assert :ok = Shims.materialize!()
    assert Bitwise.band(File.stat!(shim).mode, 0o777) == 0o755
  end

  test "materialized shim preserves an explicit app env override", %{
    shim_dir: shim_dir,
    real_dir: real_dir
  } do
    write_fake_elio!(real_dir)
    Shims.materialize!()

    {out, 0} =
      System.cmd(Shims.shim_path("elio"), [],
        env: [
          {"PATH", Enum.join([shim_dir, real_dir, "/usr/bin", "/bin"], ":")},
          {"ELIO_CLIPBOARD_OSC52", "0"}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "ELIO_CLIPBOARD_OSC52=0"
  end

  test "materialized shim installs a missing known tool before launching", %{
    shim_dir: shim_dir,
    clean_bin: clean_bin
  } do
    Shims.materialize!()
    write_fake_installer!(Shims.install_script_path("elio"), Shims.tools_bin_dir())

    {out, 0} =
      System.cmd(Shims.shim_path("elio"), ["--from-test"],
        env: [{"PATH", Enum.join([shim_dir, clean_bin], ":")}],
        stderr_to_stdout: true
      )

    assert out =~ "DevIDE: elio not found. Installing"
    assert out =~ "DevIDE: elio installed. Launching"
    assert out =~ "ELIO_CLIPBOARD_OSC52=1"
    assert out =~ "ARGV=--from-test"
  end

  test "theme env exports scheme, COLORFGBG, and optional preset" do
    assert %{
             "DEV_IDE_TERMINAL_SCHEME" => "light",
             "COLORFGBG" => "0;15",
             "DEV_IDE_TERMINAL_PRESET" => "catppuccin"
           } = Shims.theme_env(:light, "catppuccin")

    assert %{
             "DEV_IDE_TERMINAL_SCHEME" => "dark",
             "COLORFGBG" => "15;0"
           } = Shims.theme_env(:dark)
  end

  test "env merges theme variables when scheme is provided" do
    assert %{
             "DEV_IDE_TERMINAL" => "1",
             "DEV_IDE_CLIPBOARD" => "osc52",
             "DEV_IDE_TERMINAL_SCHEME" => "light",
             "COLORFGBG" => "0;15",
             "DEV_IDE_TERMINAL_PRESET" => "catppuccin"
           } = Shims.env(scheme: :light, preset: "catppuccin", include_path?: false)
  end

  test "terminal env can omit PATH for non-host execution contexts", %{shim_dir: shim_dir} do
    assert %{
             "DEV_IDE_TERMINAL" => "1",
             "DEV_IDE_CLIPBOARD" => "osc52"
           } = Shims.env(include_path?: false)

    refute Map.has_key?(Shims.env(include_path?: false), "PATH")
    assert Shims.env()["PATH"] =~ shim_dir
    assert Shims.env()["PATH"] =~ Shims.tools_bin_dir()
  end

  test "ensure-terminal-tool provisions through a temp cargo root", %{
    clean_bin: clean_bin,
    tool_root: tool_root
  } do
    write_fake_cargo!(clean_bin)

    {out, 0} =
      System.cmd(bash!(), ["scripts/ensure-terminal-tool.sh", "elio"],
        env: [
          {"PATH", clean_bin},
          {"DEV_IDE_TERMINAL_TOOLS_DIR", tool_root}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "DevIDE: provisioning terminal tool 'elio'"
    assert out =~ "DevIDE: provisioned terminal tool 'elio'"
    refute File.exists?(Path.join(tool_root, ".elio-install.lock"))

    managed_elio = Path.join([tool_root, "bin", "elio"])
    assert File.regular?(managed_elio)
    assert {installed_out, 0} = System.cmd(managed_elio, [])
    assert installed_out =~ "fake cargo elio"
  end

  test "ensure-terminal-tool check mode reports missing without installing", %{
    clean_bin: clean_bin,
    tool_root: tool_root
  } do
    write_fake_cargo!(clean_bin)

    {out, 1} =
      System.cmd(bash!(), ["scripts/ensure-terminal-tool.sh", "--check", "elio"],
        env: [
          {"PATH", clean_bin},
          {"DEV_IDE_TERMINAL_TOOLS_DIR", tool_root}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "DevIDE: elio is not installed"
    refute File.exists?(Path.join([tool_root, "bin", "elio"]))
  end

  test "generated fallback installer provisions through a temp cargo root", %{
    clean_bin: clean_bin,
    tool_root: tool_root
  } do
    write_fake_cargo!(clean_bin)
    Shims.materialize!()

    {out, 0} =
      System.cmd(Shims.install_script_path("elio"), [],
        env: [
          {"PATH", clean_bin},
          {"DEV_IDE_TERMINAL_TOOLS_DIR", tool_root}
        ],
        stderr_to_stdout: true
      )

    assert out =~ "DevIDE: provisioning terminal tool 'elio'"
    assert out =~ "DevIDE: provisioned terminal tool 'elio'"
    refute File.exists?(Path.join(tool_root, ".elio-install.lock"))

    managed_elio = Path.join([tool_root, "bin", "elio"])
    assert File.regular?(managed_elio)
    assert {installed_out, 0} = System.cmd(managed_elio, [])
    assert installed_out =~ "fake cargo elio"
  end

  defp write_fake_elio!(dir) do
    path = Path.join(dir, "elio")

    File.write!(path, fake_elio_script())
    File.chmod!(path, 0o755)
  end

  defp write_fake_installer!(path, tool_bin) do
    elio = Path.join(tool_bin, "elio")

    File.write!(path, [
      "#!/usr/bin/env bash\n",
      "set -euo pipefail\n",
      "mkdir -p #{shell_quote(tool_bin)}\n",
      "cat >#{shell_quote(elio)} <<'EOS'\n",
      fake_elio_script(),
      "EOS\n",
      "chmod +x #{shell_quote(elio)}\n"
    ])

    File.chmod!(path, 0o755)
  end

  defp write_fake_cargo!(dir) do
    path = Path.join(dir, "cargo")

    File.write!(path, [
      "#!/usr/bin/env bash\n",
      "set -euo pipefail\n",
      "root=''\n",
      "while [[ $# -gt 0 ]]; do\n",
      "  case \"$1\" in\n",
      "    install) shift ;;\n",
      "    --root) root=\"$2\"; shift 2 ;;\n",
      "    *) shift ;;\n",
      "  esac\n",
      "done\n",
      "mkdir -p \"${root}/bin\"\n",
      "cat >\"${root}/bin/elio\" <<'EOS'\n",
      "#!/usr/bin/env bash\n",
      "echo fake cargo elio\n",
      "EOS\n",
      "chmod +x \"${root}/bin/elio\"\n"
    ])

    File.chmod!(path, 0o755)
  end

  defp write_clean_bin!(dir) do
    File.mkdir_p!(dir)

    Enum.each(~w(bash env dirname mkdir cat chmod cp mv mktemp rm sleep), fn name ->
      source = System.find_executable(name) || raise "missing executable for test: #{name}"
      File.ln_s!(source, Path.join(dir, name))
    end)
  end

  defp bash!, do: System.find_executable("bash") || raise("missing bash")

  defp fake_elio_script do
    [
      "#!/usr/bin/env bash\n",
      "printf 'ELIO_CLIPBOARD_OSC52=%s\\n' \"${ELIO_CLIPBOARD_OSC52:-}\"\n",
      "printf 'DEV_IDE_APP_SHIM=%s\\n' \"${DEV_IDE_APP_SHIM:-}\"\n",
      "printf 'DEV_IDE_TERMINAL=%s\\n' \"${DEV_IDE_TERMINAL:-}\"\n",
      "printf 'DEV_IDE_CLIPBOARD=%s\\n' \"${DEV_IDE_CLIPBOARD:-}\"\n",
      "printf 'ARGV=%s\\n' \"$*\"\n"
    ]
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
