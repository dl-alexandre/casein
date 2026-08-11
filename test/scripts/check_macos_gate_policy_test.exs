defmodule Scripts.CheckMacosGatePolicyTest do
  @moduledoc """
  Hermetic coverage of scripts/check-macos-gate-policy.sh (#866).

  Drives the real guard against temp workflow/doc fixtures — never needs
  network or a live Actions run.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check-macos-gate-policy.sh", __DIR__)
  @canonical "macOS 26 arm64 (self-hosted)"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "check-macos-gate-policy-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "repo workflow + policy pass the guard" do
    {out, status} = System.cmd("bash", [@script], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "check-macos-gate-policy: ok"
  end

  test "missing package-smoke is flagged", %{tmp: tmp} do
    wf = Path.join(tmp, "bad.yml")
    doc = Path.join(tmp, "policy.md")

    File.write!(wf, """
    name: macOS desktop package
    jobs:
      other:
        name: Build and verify (#{@canonical})
        runs-on: macos-14
    """)

    File.write!(doc, good_doc())

    {out, status} = run_guard(wf, doc)
    assert status == 1
    assert out =~ "package-smoke"
  end

  test "renaming the canonical matrix name is flagged", %{tmp: tmp} do
    wf = Path.join(tmp, "renamed.yml")
    doc = Path.join(tmp, "policy.md")

    File.write!(wf, """
    name: macOS desktop package
    jobs:
      package-smoke:
        name: Build and verify (${{ matrix.name }})
        strategy:
          matrix:
            include:
              - name: "macOS renamed"
    """)

    File.write!(doc, good_doc())

    {out, status} = run_guard(wf, doc)
    assert status == 1
    assert out =~ "canonical matrix name"
  end

  test "continue-on-error is rejected", %{tmp: tmp} do
    wf = Path.join(tmp, "coe.yml")
    doc = Path.join(tmp, "policy.md")

    File.write!(wf, good_workflow_body() <> "\n      continue-on-error: true\n")
    File.write!(doc, good_doc())

    {out, status} = run_guard(wf, doc)
    assert status == 1
    assert out =~ "continue-on-error"
  end

  test "policy doc must restate REQUIRED", %{tmp: tmp} do
    wf = Path.join(tmp, "ok.yml")
    doc = Path.join(tmp, "thin.md")

    File.write!(wf, good_workflow_body())
    File.write!(doc, "ci/macos-quarantine\nauto-merge\n#865\n#{@canonical}\n")

    {out, status} = run_guard(wf, doc)
    assert status == 1
    assert out =~ "REQUIRED"
  end

  test "compliant fixture passes", %{tmp: tmp} do
    wf = Path.join(tmp, "ok.yml")
    doc = Path.join(tmp, "ok.md")

    File.write!(wf, good_workflow_body())
    File.write!(doc, good_doc())

    {out, status} = run_guard(wf, doc)
    assert status == 0, out
    assert out =~ "ok"
  end

  defp run_guard(workflow, doc) do
    System.cmd("bash", [@script],
      env: [
        {"MACOS_DESKTOP_WORKFLOW", workflow},
        {"MACOS_GATE_POLICY_DOC", doc}
      ],
      stderr_to_stdout: true
    )
  end

  defp good_doc do
    """
    The macOS gate STAYS REQUIRED.
    Quarantine label: ci/macos-quarantine
    Auto-merge interaction documented.
    Infra fix: #865
    Check name freeze: Build and verify (#{@canonical})
    """
  end

  defp good_workflow_body do
    """
    name: macOS desktop package
    jobs:
      package-smoke:
        name: Build and verify (${{ matrix.name }})
        strategy:
          matrix:
            include:
              - name: "#{@canonical}"
                runner: [self-hosted, macOS]
        steps:
          - run: scripts/package-macos-desktop.sh
    """
  end
end
