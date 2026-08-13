defmodule Scripts.CheckNpmAuditGuardTest do
  @moduledoc """
  Hermetic coverage of scripts/check-npm-audit-guard.sh and scripts/npm-audit.sh
  (#929).

  Drives the real scripts against the live tree and planted temp trees —
  never mutates the checkout.
  """
  use ExUnit.Case, async: true

  @guard Path.expand("../../scripts/check-npm-audit-guard.sh", __DIR__)
  @audit Path.expand("../../scripts/npm-audit.sh", __DIR__)

  test "scripts have valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @guard])
    assert {_, 0} = System.cmd("bash", ["-n", @audit])
  end

  test "current tree's install sites all run npm audit" do
    {output, status} = System.cmd("bash", [@guard], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "install site"
    assert output =~ "npm audit"
  end

  test "npm-audit.sh pins --audit-level=high and never lowers it" do
    content = File.read!(@audit)

    assert content =~ "--audit-level=${LEVEL}"
    assert content =~ ~s(NPM_AUDIT_LEVEL:-high)
    refute content =~ "--audit-level=low"
    refute content =~ "--audit-level=moderate"
    refute content =~ "--audit-level=info"
  end

  test "current lockfiles pass --audit-level=high" do
    {output, status} = System.cmd("bash", [@audit], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "assets"
    assert output =~ "priv/scripts"
  end

  test "guard flags a planted install that keeps --no-audit and never scans", %{tmp: tmp} do
    plant_audit_script!(tmp)

    File.mkdir_p!(Path.join(tmp, ".github/workflows"))

    File.write!(Path.join(tmp, ".github/workflows/bad.yml"), """
    jobs:
      build:
        run: npm --prefix assets ci --no-audit --no-fund
    """)

    {output, status} = run_guard(tmp)

    assert status == 1, output
    assert output =~ "bad.yml"
    assert output =~ "never runs npm-audit.sh or npm audit"
  end

  test "guard accepts a planted install that invokes npm-audit.sh", %{tmp: tmp} do
    plant_audit_script!(tmp)

    File.mkdir_p!(Path.join(tmp, "scripts"))

    File.write!(Path.join(tmp, "scripts/install.sh"), """
    #!/usr/bin/env bash
    npm ci --no-audit --no-fund
    bash scripts/npm-audit.sh
    """)

    {output, status} = run_guard(tmp)

    assert status == 0, output
  end

  test "guard ignores global npm install -g tooling", %{tmp: tmp} do
    plant_audit_script!(tmp)

    File.mkdir_p!(Path.join(tmp, "scripts"))

    File.write!(Path.join(tmp, "scripts/ensure-preview-walk-deps.sh"), """
    #!/usr/bin/env bash
    npm install -g playwright-core
    """)

    {output, status} = run_guard(tmp)

    assert status == 0, output
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "check-npm-audit-guard-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp plant_audit_script!(tmp) do
    File.mkdir_p!(Path.join(tmp, "scripts"))

    File.write!(Path.join(tmp, "scripts/npm-audit.sh"), """
    #!/usr/bin/env bash
    npm audit --package-lock-only --audit-level=high
    """)
  end

  defp run_guard(tmp) do
    System.cmd("bash", [@guard],
      env: [{"NPM_AUDIT_GUARD_ROOT", tmp}],
      stderr_to_stdout: true
    )
  end
end
