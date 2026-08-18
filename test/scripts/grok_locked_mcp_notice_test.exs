defmodule Casein.Scripts.GrokLockedMcpNoticeTest do
  @moduledoc """
  A managed Grok worker launched without a write-capable MCP grant must SAY
  what is and is not available to it.

  History: the launcher used to select Grok's `read-only` bwrap base whenever
  write was unavailable. That conflated two unrelated risks — writing an isolated
  worktree versus driving the operator's live panes — and it was severe and
  silent: the worktree and its git metadata were write-denied, child network was
  blocked, and BEAM could not start (`Failed to write to erl_child_setup: 1`), so
  `mix` would not run. The pane still reached a normal-looking prompt, so several
  sessions diagnosed it locally and one concluded Grok's OAuth had expired when
  the credential was in fact healthy.

  The base is now always `strict`; DB isolation governs the MCP grant only. These
  assertions cover both halves: that the sandbox no longer keys off write_enabled,
  and that a locked launch stays legible about the grant it did get.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/launch-casein-agent.sh", __DIR__)

  setup_all do
    assert File.exists?(@script), "launcher missing at #{@script}"
    %{source: File.read!(@script)}
  end

  test "the bwrap base never keys off write_enabled", %{source: source} do
    refute source =~ ~s(sandbox_base="read-only"),
           """
           The read-only base is what made a locked worker useless: no worktree
           write, no child network, no BEAM. Isolation comes from the worker's own
           fresh worktree, not from denying it write.
           """

    assert source =~ ~s(sandbox_base="strict"),
           "the managed leader must still pin an explicit bwrap base"

    # The decision site must not branch on write_enabled at all — a base chosen
    # inside that conditional is the regression this test exists to catch.
    [_, branch] = String.split(source, ~s(if [[ "$write_enabled" != "true" ]]; then), parts: 2)
    [branch, _] = String.split(branch, "profile=", parts: 2)

    refute branch =~ "sandbox_base=",
           "the sandbox base must be selected before, and independently of, the write check"
  end

  test "a locked launch announces the grant it actually got", %{source: source} do
    assert source =~ "grok_announce_locked_mcp_grant() {",
           "the notice function was removed"

    [_, branch] = String.split(source, ~s(if [[ "$write_enabled" != "true" ]]; then), parts: 2)
    [branch, _] = String.split(branch, "profile=", parts: 2)

    assert branch =~ "grok_announce_locked_mcp_grant",
           "a locked MCP grant is selected without announcing it — that is the silent failure"
  end

  test "orchestrator preset refuses a locked grant instead of launching", %{source: source} do
    assert source =~ "grok_refuse_locked_orchestrator() {",
           "CASEIN_AGENT_REQUIRE_WRITE must have a hard refuse path"

    assert source =~ ~s(CASEIN_AGENT_REQUIRE_WRITE:-0),
           "the refuse gate must be opt-in so workers still advise-and-proceed"

    assert source =~ "exit 3",
           "orchestrator refuse must exit non-zero so callers do not treat it as a healthy launch"

    [_, branch] = String.split(source, ~s(if [[ "$write_enabled" != "true" ]]; then), parts: 2)
    [branch, _] = String.split(branch, "profile=", parts: 2)

    assert branch =~ "grok_refuse_locked_orchestrator",
           "REQUIRE_WRITE must run before announce so orchestrators never reach a locked prompt"
  end

  test "the notice forbids sandbox-base bypass of the isolation gate", %{source: source} do
    notice = notice_body(source)

    assert notice =~ "CASEIN_GROK_SANDBOX_BASE",
           "the wrong fix (override the sandbox) must be named so operators do not reach for it"

    assert notice =~ "CASEIN_AGENT_REQUIRE_WRITE",
           "point orchestrators at the fail-fast launch flag"
  end

  test "the notice states what the worker CAN do, so a working sandbox is not re-diagnosed", %{
    source: source
  } do
    notice = notice_body(source)

    assert notice =~ ~r/CAN write its own worktree/,
           """
           The expensive failure mode is a worker assuming it is crippled. The
           notice must affirm worktree write explicitly.
           """

    assert notice =~ "mix",
           "running mix is the capability whose absence previously read as a broken toolchain"

    assert notice =~ ~r/strict/,
           "name the actual base so it is greppable against sandbox.toml"
  end

  test "the notice states what the worker CANNOT do, and why", %{source: source} do
    notice = notice_body(source)

    assert notice =~ ~r/CANNOT drive your live tmux panes/,
           "the one real restriction must be stated plainly"

    assert notice =~ "terminal_send_command",
           "name the missing tool so it is greppable"

    assert notice =~ "isolation",
           "the notice must name the cause; a symptom-only message sends people looking locally"

    refute notice =~ "Unlock 30"
    refute notice =~ "agent-write unlock"
  end

  test "the notice says delegation still works while locked", %{source: source} do
    notice = notice_body(source)

    assert notice =~ "terminal_report_agent_state",
           """
           Reporting tools survive a locked grant, so delegation is viable without
           pane mutations. Omitting this is what made operators chase a write grant.
           """
  end

  test "the notice tells the reader how to lift the restriction", %{source: source} do
    notice = notice_body(source)

    assert notice =~ ~r/isolation/i, "the notice should say what to fix"
    assert notice =~ ~r/relaunch/i, "changing isolation does not re-issue a live capability"
  end

  test "the notice goes to stderr so it survives stdout capture", %{source: source} do
    notice = notice_body(source)

    assert notice =~ ">&2",
           "launcher output is frequently piped; the warning must not vanish into a pipe"
  end

  defp notice_body(source) do
    [_, rest] = String.split(source, "grok_announce_locked_mcp_grant() {", parts: 2)
    [body, _] = String.split(rest, "\n}", parts: 2)
    body
  end
end
