defmodule Scripts.PrePushCheckTest do
  @moduledoc """
  Guards the pre-push gate's run-recording contract: the script must report
  its verdict to Casein via the terminal MCP `gate_report` tool, and that
  reporting must be fail-open on every path — a dead API, missing env, or
  missing python3 must never change the gate's exit code.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/pre-push-check.sh", __DIR__)
  @repo_root Path.expand("../..", __DIR__)
  @native_command_order [
    "deps.get",
    "test test/casein_mob/plugin_supply_chain_test.exs test/casein_mob/mob_dev_native_deploy_contract_test.exs test/casein_mob/android_cmake_zig_fallback_test.exs",
    "mob.regen_plugin_manifest --check"
  ]

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "reports the gate verdict through the gate_report terminal tool" do
    content = File.read!(@script)

    # Verdict reporting is wired as an EXIT trap so both pass and fail runs
    # report, and the trap itself can never flip the gate's exit code.
    assert content =~ "trap 'report_gate_result \"$?\" || true' EXIT"
    assert content =~ "\\\"name\\\":\\\"gate_report\\\""
    assert content =~ "\"workspace_id\": os.environ[\"CASEIN_WORKSPACE_ID\"]"
  end

  test "gate reporting is fail-open on every path" do
    content = File.read!(@script)

    # Skipped silently without the workspace env vars.
    assert content =~
             "[[ -n \"${CASEIN_API_TOKEN:-}\" && -n \"${CASEIN_WORKSPACE_ID:-}\" ]] || return 0"

    # Skipped when the helper binaries are missing.
    assert content =~ "command -v python3 >/dev/null 2>&1 || return 0"
    assert content =~ "command -v curl >/dev/null 2>&1 || return 0"

    # Short curl timeout, output swallowed, and never a gate failure.
    assert content =~ "--max-time 5"
    assert content =~ "-d \"${rpc_body}\" >/dev/null 2>&1 || true"
  end

  test "the last announced step is captured for failed_step" do
    content = File.read!(@script)

    assert content =~ "log() { printf '>>> %s\\n' \"$*\"; GATE_CURRENT_STEP=\"$*\"; }"
    assert content =~ "failed_step=\"${GATE_CURRENT_STEP}\""
  end

  test "isolates inherited root dependencies and preserves native command order" do
    content = File.read!(@script)
    block = native_supply_chain_block(content)
    tmp = unique_tmp_dir!()
    on_exit(fn -> File.rm_rf(tmp) end)

    root_deps = Path.join(tmp, "shared root deps with spaces")
    File.mkdir_p!(root_deps)
    sentinel = Path.join(root_deps, "root-cache-sentinel")
    File.write!(sentinel, "root-owned\n")

    isolated_deps = root_deps <> "-casein-mob"
    File.mkdir_p!(isolated_deps)
    isolated_sentinel = Path.join(isolated_deps, "persistent-cache-sentinel")
    File.write!(isolated_sentinel, "keep-me\n")

    records = run_native_block!(block, tmp, root_deps <> "/")
    {native_records, [root_record]} = Enum.split(records, 3)
    native_dir = Path.join(@repo_root, "native/casein_mob")

    assert Enum.map(native_records, & &1.args) == @native_command_order
    assert Enum.all?(native_records, &(&1.exported_deps == isolated_deps))
    assert Enum.all?(native_records, &(&1.effective_deps == isolated_deps))
    assert Enum.all?(native_records, &(&1.cwd == native_dir))
    assert File.read!(sentinel) == "root-owned\n"
    refute File.exists?(Path.join(root_deps, "nested-command-write"))
    assert File.read!(Path.join(isolated_deps, "nested-command-write")) == "nested-owned\n"
    assert File.read!(isolated_sentinel) == "keep-me\n"

    assert root_record == %{
             args: "root.postcheck",
             cwd: @repo_root,
             effective_deps: root_deps <> "/",
             exported_deps: root_deps <> "/"
           }
  end

  test "leaves MIX_DEPS_PATH unset so native Mix uses its normal deps directory" do
    content = File.read!(@script)
    block = native_supply_chain_block(content)
    tmp = unique_tmp_dir!()
    on_exit(fn -> File.rm_rf(tmp) end)

    records = run_native_block!(block, tmp, nil)
    {native_records, [root_record]} = Enum.split(records, 3)
    native_dir = Path.join(@repo_root, "native/casein_mob")

    assert Enum.map(native_records, & &1.args) == @native_command_order
    assert Enum.all?(native_records, &(&1.exported_deps == "<unset>"))

    assert Enum.all?(
             native_records,
             &(&1.effective_deps == Path.join(native_dir, "deps"))
           )

    assert Enum.all?(native_records, &(&1.cwd == native_dir))

    assert root_record == %{
             args: "root.postcheck",
             cwd: @repo_root,
             effective_deps: Path.join(@repo_root, "deps"),
             exported_deps: "<unset>"
           }
  end

  defp native_supply_chain_block(content) do
    marker =
      ~r/log "checking native plugin supply-chain signatures and committed manifest"\n(\(\n.*?\n\))\n\n# precommit/s

    [_, block] = Regex.run(marker, content)
    block
  end

  defp unique_tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "casein native gate #{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp run_native_block!(block, tmp, root_deps) do
    fake_mix = Path.join(tmp, "fake mix")
    record_path = Path.join(tmp, "commands.tsv")

    File.write!(fake_mix, """
    #!/usr/bin/env bash
    set -euo pipefail
    exported_deps="${MIX_DEPS_PATH-<unset>}"
    effective_deps="${MIX_DEPS_PATH:-${PWD}/deps}"
    printf '%s\\t%s\\t%s\\t%s\\n' \
      "${exported_deps}" "${effective_deps}" "${PWD}" "$*" >>"${CASEIN_TEST_RECORD}"
    if [[ "$1" == "deps.get" && "${exported_deps}" != "<unset>" ]]; then
      mkdir -p "${exported_deps}"
      printf 'nested-owned\\n' >"${exported_deps}/nested-command-write"
    fi
    """)

    File.chmod!(fake_mix, 0o755)

    inherited_setup =
      if root_deps do
        ~S(export MIX_DEPS_PATH="${CASEIN_TEST_ROOT_DEPS}")
      else
        "unset MIX_DEPS_PATH"
      end

    runner = """
    set -euo pipefail
    ROOT="${CASEIN_TEST_REPO}"
    cd "${ROOT}"
    MIX=("${CASEIN_TEST_FAKE_MIX}")
    #{inherited_setup}
    #{block}
    "${MIX[@]}" root.postcheck
    """

    env = [
      {"CASEIN_TEST_REPO", @repo_root},
      {"CASEIN_TEST_FAKE_MIX", fake_mix},
      {"CASEIN_TEST_RECORD", record_path},
      {"CASEIN_TEST_ROOT_DEPS", root_deps || ""}
    ]

    # /bin/bash is the macOS Bash 3.2 baseline used by local developers.
    assert {"", 0} = System.cmd("/bin/bash", ["-c", runner], env: env, stderr_to_stdout: true)

    record_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [exported_deps, effective_deps, cwd, args] = String.split(line, "\t", parts: 4)

      %{
        exported_deps: exported_deps,
        effective_deps: effective_deps,
        cwd: cwd,
        args: args
      }
    end)
  end
end
