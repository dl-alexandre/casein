defmodule Scripts.VerifyWindowsPreviewMcpCleanHostTest do
  @moduledoc """
  Hermetic guards for the #463 clean Win11 Preview MCP evidence gate.

  Never claims a clean-host walk passed. Pins: dry-run keeps clean_host false,
  validator rejects secrets and dishonest walk_passed, and docs name the gate.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/verify_windows_preview_mcp_clean_host.sh", __DIR__)
  @schema Path.expand(
            "../../scripts/schemas/windows_preview_mcp_clean_host_evidence.schema.json",
            __DIR__
          )
  @lab_doc Path.expand("../../docs/desktop/windows_preview_mcp_clean_host.md", __DIR__)
  @parity Path.expand("../../docs/desktop/windows_prod_parity.md", __DIR__)
  @bridge_script Path.expand("../../scripts/verify_preview_bridge_file_page.mjs", __DIR__)

  @step_ids ~w(discover open observe click type press screenshot close)

  setup do
    tmp = Path.join(System.tmp_dir!(), "casein-463-lab-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "script and schema exist; script has valid shell syntax" do
    assert File.exists?(@script)
    assert File.exists?(@schema)
    assert File.exists?(@bridge_script)
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "help names issue 463 and does not claim clean-host pass" do
    {out, status} = System.cmd("bash", [@script, "--help"], stderr_to_stdout: true)
    assert status == 0
    assert out =~ "463"
    assert out =~ "dry-run"
    assert out =~ "validate-evidence"
    assert out =~ "not clean-machine acceptance"
  end

  test "schema pins fixed mcp step ids and forbids additional properties" do
    schema = Jason.decode!(File.read!(@schema))
    assert schema["properties"]["schema"]["const"] == "casein_windows_preview_mcp_clean_host"
    assert schema["properties"]["issue"]["const"] == 463
    assert schema["additionalProperties"] == false

    step_enum = get_in(schema, ["$defs", "mcp_step", "properties", "id", "enum"])
    assert step_enum == @step_ids
  end

  test "lab runbook declares honesty matrix and forbidden evidence" do
    doc = File.read!(@lab_doc)
    assert doc =~ "#463"
    assert doc =~ "lab_unreachable_on_this_host"
    assert doc =~ "What this box can and cannot prove"
    assert doc =~ "verify_preview_bridge_file_page"
    assert doc =~ "not** clean-machine" or doc =~ "not clean-machine"
  end

  test "parity doc points at the clean-host evidence gate" do
    parity = File.read!(@parity)
    assert parity =~ "windows_preview_mcp_clean_host"
    assert parity =~ "verify_windows_preview_mcp_clean_host"
  end

  test "dry-run writes lab_unreachable and never sets clean_host claims", %{tmp: tmp} do
    evidence = Path.join(tmp, "self.json")

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--dry-run", "--evidence", evidence],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "lab_unreachable_on_this_host"

    doc = Jason.decode!(File.read!(evidence))
    assert doc["verdict"] == "lab_unreachable_on_this_host"
    assert doc["issue"] == 463
    assert doc["claims"]["clean_host_exercised"] == false
    assert doc["claims"]["agent_inside_installed_workspace"] == false
    assert doc["claims"]["linux_dry_run"] == true
    assert length(doc["mcp_steps"]) == 8
    assert Enum.map(doc["mcp_steps"], & &1["id"]) == @step_ids
    assert Enum.all?(doc["mcp_steps"], &(&1["outcome"] == "not_run"))
  end

  test "print-template is lab_incomplete with all steps not_run" do
    {out, status} = System.cmd("bash", [@script, "--print-template"], stderr_to_stdout: true)
    assert status == 0
    doc = Jason.decode!(out)
    assert doc["verdict"] == "lab_incomplete"
    assert doc["claims"]["clean_host_exercised"] == false
    assert length(doc["mcp_steps"]) == 8
    assert Enum.all?(doc["mcp_steps"], &(&1["outcome"] == "not_run"))
  end

  test "validate-evidence accepts dry-run output", %{tmp: tmp} do
    evidence = Path.join(tmp, "self.json")

    {_, 0} =
      System.cmd("bash", [@script, "--dry-run", "--evidence", evidence], stderr_to_stdout: true)

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", evidence], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "lab_unreachable_on_this_host"
  end

  test "validate-evidence rejects secret-like bearer text", %{tmp: tmp} do
    path = Path.join(tmp, "secret.json")
    doc = base_doc()
    doc = put_in(doc, ["mcp_steps", Access.at(0), "notes"], "bearer abcdef123456")
    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
    assert out =~ "secret" or out =~ "ERROR"
  end

  test "validate-evidence rejects dishonest walk_passed without clean host", %{tmp: tmp} do
    path = Path.join(tmp, "fake-pass.json")

    doc =
      base_doc()
      |> Map.put("verdict", "walk_passed")
      |> put_in(["claims", "clean_host_exercised"], true)
      |> put_in(["claims", "agent_inside_installed_workspace"], true)

    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
  end

  test "validate-evidence accepts honest walk_passed", %{tmp: tmp} do
    path = Path.join(tmp, "pass.json")
    File.write!(path, Jason.encode!(walk_passed_doc()))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "walk_passed"
  end

  test "script never claims clean-host pass from dry-run" do
    content = File.read!(@script)
    assert content =~ "lab_unreachable_on_this_host"
    assert content =~ "\"clean_host_exercised\": False"
    assert content =~ "NEVER pretends"
    refute content =~ "xcrun simctl"
  end

  test "bridge file-page script names honesty bounds" do
    content = File.read!(@bridge_script)
    assert content =~ "preview_bridge.js"
    assert content =~ "esbuild"
    assert content =~ "file://"
    assert content =~ "does_not_prove"
    assert content =~ "clean_win11_signed_install"
    assert content =~ "casein_preview=1"
  end

  defp base_doc do
    steps =
      Enum.map(@step_ids, fn id ->
        %{"id" => id, "outcome" => "not_run", "notes" => ""}
      end)

    %{
      "schema" => "casein_windows_preview_mcp_clean_host",
      "schema_version" => 1,
      "issue" => 463,
      "recorded_at_utc" => "2026-08-10T12:00:00Z",
      "product_revision" => String.duplicate("a", 40),
      "package_sha" => String.duplicate("b", 40),
      "operator" => "test",
      "host" => %{
        "os" => "Windows 11",
        "kind" => "clean_win11_signed_install",
        "package_signed" => false,
        "hostname_redacted" => "win11-*",
        "notes" => ""
      },
      "claims" => %{
        "clean_host_exercised" => false,
        "agent_inside_installed_workspace" => false,
        "package_smoke_only" => false,
        "linux_dry_run" => false,
        "secrets_redacted" => true
      },
      "mcp_steps" => steps,
      "attachments" => %{
        "screenshot_count" => 0,
        "log_refs" => [],
        "issue_comment_urls" => []
      },
      "verdict" => "lab_incomplete"
    }
  end

  defp walk_passed_doc do
    steps =
      Enum.map(@step_ids, fn id ->
        %{
          "id" => id,
          "outcome" => "passed",
          "at_utc" => "2026-08-10T12:00:00Z",
          "notes" => "ok"
        }
      end)

    base_doc()
    |> Map.put("verdict", "walk_passed")
    |> put_in(["claims", "clean_host_exercised"], true)
    |> put_in(["claims", "agent_inside_installed_workspace"], true)
    |> put_in(["host", "package_signed"], true)
    |> Map.put("mcp_steps", steps)
  end
end
