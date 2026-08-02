defmodule Casein.Scripts.GrokReadOnlySandboxNoticeTest do
  @moduledoc """
  A managed Grok worker that lands in the read-only sandbox must SAY SO.

  The read-only bwrap profile write-denies the worktree and its git metadata,
  blocks child network, and breaks BEAM (`Failed to write to erl_child_setup: 1`)
  so `mix` will not run. Before the notice, none of that was announced — the pane
  reached a normal-looking prompt and the worker only discovered the problem by
  failing at something unrelated. Two sessions lost real time to it, and the cause
  is never local: the workspace's agent-write unlock is expired or absent.

  These assertions are about *legibility*, not about the sandbox policy itself.
  The policy is deliberate; the silence was the bug.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/launch-casein-agent.sh", __DIR__)

  setup_all do
    assert File.exists?(@script), "launcher missing at #{@script}"
    %{source: File.read!(@script)}
  end

  test "the notice function exists and is invoked on the read-only branch", %{source: source} do
    assert source =~ "grok_announce_read_only_sandbox() {",
           "the notice function was removed"

    # Isolate the sandbox_base decision and assert the notice sits on the
    # read-only side of it, not merely somewhere in the file.
    [_, branch] = String.split(source, ~s(if [[ "$write_enabled" == "true" ]]; then), parts: 2)
    [branch, _] = String.split(branch, "profile=", parts: 2)

    assert branch =~ "sandbox_base=\"read-only\"", "read-only branch not found"

    assert branch =~ "grok_announce_read_only_sandbox",
           "read-only sandbox is selected without announcing it — that is the silent failure"

    refute branch
           |> String.split("sandbox_base=\"strict\"", parts: 2)
           |> hd()
           |> String.contains?("grok_announce_read_only_sandbox"),
           "the notice must not fire on the writable (strict) path"
  end

  test "the notice names the cause, not just the symptom", %{source: source} do
    notice = notice_body(source)

    assert notice =~ "READ-ONLY",
           "the notice must state the sandbox is read-only"

    assert notice =~ "agent-write unlock",
           "the notice must name the actual cause; a symptom-only message sends people looking locally"

    assert notice =~ "terminal_send_agent_command",
           "the notice should name the missing capability so it is greppable"
  end

  test "the notice tells the reader what to do, including the safe alternative", %{
    source: source
  } do
    notice = notice_body(source)

    assert notice =~ "codex",
           "the notice should point at the delegation path that actually works while locked"

    assert notice =~ ~r/re-grant|operator/i,
           "the notice should say who can fix it"
  end

  test "the notice warns against the override a blocked worker will suggest", %{source: source} do
    notice = notice_body(source)

    assert notice =~ "CASEIN_GROK_SANDBOX_BASE",
           "the notice must mention the override by name so the warning is findable"

    assert notice =~ ~r/Do NOT|do not/,
           """
           The override must be discouraged explicitly. A blocked worker will propose
           setting CASEIN_GROK_SANDBOX_BASE itself; following that circumvents a
           deliberate, time-boxed control rather than satisfying it.
           """
  end

  test "the notice goes to stderr so it survives stdout capture", %{source: source} do
    notice = notice_body(source)

    assert notice =~ ">&2",
           "launcher output is frequently piped; the warning must not vanish into a pipe"
  end

  defp notice_body(source) do
    [_, rest] = String.split(source, "grok_announce_read_only_sandbox() {", parts: 2)
    [body, _] = String.split(rest, "\n}", parts: 2)
    body
  end
end
