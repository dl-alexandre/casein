defmodule Scripts.SkippableArtifactUploadTest do
  @moduledoc """
  Hermetic guards for the #382 skippable artifact-upload helper.

  Never talks to GitHub Actions. Pins: default mode skips remote upload,
  stage always produces a receipt, upload mode propagates command failure,
  and the helper never claims to replace build/sign/verify.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../scripts/lib/skippable-artifact-upload.sh", __DIR__)
  @wrap Path.expand("../../scripts/stage-macos-desktop-artifacts.sh", __DIR__)

  # System.cmd/3 merges env with the parent — delete override vars for children.
  @clear_env [
    {"CASEIN_ARTIFACT_UPLOAD_MODE", nil},
    {"CASEIN_ARTIFACT_UPLOAD_CMD", nil},
    {"CASEIN_ARTIFACT_STAGE_ROOT", nil},
    {"CASEIN_ARTIFACT_LABEL", nil},
    {"CASEIN_ARTIFACT_SOURCE", nil},
    {"RUNNER_NAME", nil},
    {"GITHUB_RUN_ID", nil}
  ]

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "casein-skippable-upload-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "lib and wrapper exist with valid shell syntax" do
    assert File.exists?(@lib)
    assert File.exists?(@wrap)
    assert {_, 0} = System.cmd("bash", ["-n", @lib])
    assert {_, 0} = System.cmd("bash", ["-n", @wrap])
  end

  test "default mode stages files and skips remote upload", %{tmp: tmp} do
    src = Path.join(tmp, "src")
    dest = Path.join(tmp, "dest")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Casein-1.0-macos-arm64.zip"), "zip-bytes")
    File.write!(Path.join(src, "Casein-1.0-macos-arm64.evidence.json"), "{\"ok\":true}")

    assert {out, 0} =
             System.cmd(
               "bash",
               [
                 @lib,
                 "--label",
                 "test-label",
                 "--source",
                 src,
                 "--dest",
                 dest,
                 "--glob",
                 "Casein-*"
               ],
               env: @clear_env,
               stderr_to_stdout: true
             )

    assert out =~ "mode=skip"
    assert out =~ "upload: attempted=0 skipped=1"
    assert File.exists?(Path.join(dest, "Casein-1.0-macos-arm64.zip"))
    assert File.exists?(Path.join(dest, "Casein-1.0-macos-arm64.evidence.json"))

    receipt = Path.join(dest, "upload-receipt.json")
    assert File.exists?(receipt)
    {:ok, json} = Jason.decode(File.read!(receipt))
    assert json["schema"] == "casein.skippable_artifact_upload/v1"
    assert json["mode"] == "skip"
    assert json["upload"]["skipped"] == true
    assert json["upload"]["attempted"] == false
    assert json["upload"]["ok"] == false
    assert "Casein-1.0-macos-arm64.zip" in json["staged_file_names"]
    assert is_list(json["proven_here"])
    assert is_list(json["needs_human"])
    assert json["quota_note"] =~ "upload-artifact"
  end

  test "mode=upload runs command with staged path and succeeds", %{tmp: tmp} do
    src = Path.join(tmp, "src")
    dest = Path.join(tmp, "dest")
    marker = Path.join(tmp, "uploaded-from")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "pkg.zip"), "data")

    cmd = "printf '%s' '{}' > #{marker}"

    assert {_out, 0} =
             System.cmd(
               "bash",
               [
                 @lib,
                 "--label",
                 "up",
                 "--source",
                 src,
                 "--dest",
                 dest,
                 "--mode",
                 "upload",
                 "--upload-cmd",
                 cmd,
                 "--glob",
                 "*.zip"
               ],
               env: @clear_env,
               stderr_to_stdout: true
             )

    assert File.exists?(marker)
    assert String.trim(File.read!(marker)) == dest

    receipt = Jason.decode!(File.read!(Path.join(dest, "upload-receipt.json")))
    assert receipt["mode"] == "upload"
    assert receipt["upload"]["attempted"] == true
    assert receipt["upload"]["skipped"] == false
    assert receipt["upload"]["ok"] == true
  end

  test "mode=upload propagates remote command failure as exit 4", %{tmp: tmp} do
    src = Path.join(tmp, "src")
    dest = Path.join(tmp, "dest")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "pkg.zip"), "data")

    assert {out, 4} =
             System.cmd(
               "bash",
               [
                 @lib,
                 "--label",
                 "fail",
                 "--source",
                 src,
                 "--dest",
                 dest,
                 "--mode",
                 "upload",
                 "--upload-cmd",
                 "exit 9",
                 "--glob",
                 "*.zip"
               ],
               env: @clear_env,
               stderr_to_stdout: true
             )

    assert out =~ "failed with exit 9" || out =~ "exit 9"
    receipt = Jason.decode!(File.read!(Path.join(dest, "upload-receipt.json")))
    assert receipt["upload"]["ok"] == false
    assert receipt["upload"]["exit_code"] == 9
  end

  test "missing source exits 1", %{tmp: tmp} do
    assert {_out, 1} =
             System.cmd(
               "bash",
               [
                 @lib,
                 "--label",
                 "x",
                 "--source",
                 Path.join(tmp, "nope"),
                 "--dest",
                 Path.join(tmp, "d")
               ],
               env: @clear_env,
               stderr_to_stdout: true
             )
  end

  test "empty match exits 2", %{tmp: tmp} do
    src = Path.join(tmp, "empty")
    File.mkdir_p!(src)

    assert {_out, 2} =
             System.cmd(
               "bash",
               [
                 @lib,
                 "--label",
                 "x",
                 "--source",
                 src,
                 "--dest",
                 Path.join(tmp, "d"),
                 "--glob",
                 "no-such-*"
               ],
               env: @clear_env,
               stderr_to_stdout: true
             )
  end

  test "wrapper delegates to lib with macos defaults", %{tmp: tmp} do
    src = Path.join(tmp, "artifacts")
    dest = Path.join(tmp, "staged")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Casein-9-macos-x86_64.zip"), "z")
    File.write!(Path.join(src, "Casein-9-macos-x86_64.sha256"), "abc")

    assert {out, 0} =
             System.cmd(
               "bash",
               [
                 @wrap,
                 "--label",
                 "wrap-test",
                 "--source",
                 src,
                 "--dest",
                 dest,
                 "--mode",
                 "skip"
               ],
               env: @clear_env,
               stderr_to_stdout: true
             )

    assert out =~ "mode=skip"
    assert File.exists?(Path.join(dest, "Casein-9-macos-x86_64.zip"))
    assert File.exists?(Path.join(dest, "upload-receipt.json"))
  end

  test "helper documents quota without hacking workflows green" do
    lib = File.read!(@lib)
    wrap = File.read!(@wrap)

    assert lib =~ "upload-artifact"
    assert lib =~ "quota"
    assert lib =~ "#382"
    assert lib =~ "never weakens verification" || lib =~ "Never skips build/sign/verify"
    refute lib =~ "windows-desktop.yml"
    refute wrap =~ "windows-desktop.yml"
    # Scripts-only slice: must not instruct editing workflows to fake green.
    refute lib =~ "continue-on-error: true"
    refute wrap =~ "continue-on-error: true"
  end
end
