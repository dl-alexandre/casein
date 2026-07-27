defmodule Casein.Release.PackageScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/package-release.sh", __DIR__)
  @macos_script Path.expand("../../../scripts/package-macos-desktop.sh", __DIR__)

  test "package script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "package script is explicitly LAN-only in v1" do
    text = File.read!(@script)

    assert text =~ "unsupported profile"
    assert text =~ "v1 packaging supports only --profile lan"
    assert text =~ "REPO_ADAPTER=sqlite"
    assert text =~ "export CASEIN_REPO_ADAPTER=\"${REPO_ADAPTER}\""
  end

  test "package script writes sha256sum-compatible sidecars" do
    text = File.read!(@script)

    assert text =~ "sha256sum \"$(basename \""
    assert text =~ "sha256sum -c $(basename \"${SHA_FILE}\")"
  end

  test "macOS package script isolates the project version from compilation output" do
    assert {_, 0} = System.cmd("bash", ["-n", @macos_script])

    text = File.read!(@macos_script)

    assert text =~ ~s(IO.puts("CASEIN_PROJECT_VERSION=")
    assert text =~ ~s(sed -n 's/^CASEIN_PROJECT_VERSION=//p')
    assert text =~ ~s([[ -z "$version" || "$version" == *$'\\n'* ]])
  end
end
