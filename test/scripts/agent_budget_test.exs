defmodule Scripts.AgentBudgetTest do
  @moduledoc """
  Hermetic coverage of scripts/lib/agent-budget.sh.

  Drives the real helper against a planted process list — never depends on
  how many agents happen to be running on the host executing the suite.
  """
  use ExUnit.Case, async: true

  @helper Path.expand("../../scripts/lib/agent-budget.sh", __DIR__)
  @launcher Path.expand("../../scripts/launch-casein-agent.sh", __DIR__)
  @spawn Path.expand("../../scripts/spawn-agent-worker.sh", __DIR__)

  test "helper has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @helper])
  end

  test "both launchers source the budget helper and call the gate" do
    for script <- [@launcher, @spawn] do
      body = File.read!(script)
      assert body =~ "scripts/lib/agent-budget.sh", Path.basename(script)
      assert body =~ "agent_budget_check", Path.basename(script)
    end
  end

  test "accepts a launch under both limits" do
    ps = ps_fixture(devbox: 3, jhanf: 2)
    {out, status} = run_check(ps, "devbox", [])
    assert status == 0, out
    refute out =~ "refused"
  end

  test "refuses loudly at the host-wide limit with a machine-readable token" do
    ps = ps_fixture(devbox: 4, jhanf: 4, mtinker: 4)

    {out, status} = run_check(ps, "devbox", [{"CASEIN_AGENT_MAX_TOTAL", "12"}])
    assert status == 75, out
    assert out =~ "launch refused"
    assert out =~ "12 agent processes already resident host-wide (limit 12)"
    assert out =~ ~r/^refused:budget$/m
    refute out =~ "proceed:budget-force"
  end

  test "refuses at the per-user limit even when the host has room" do
    ps = ps_fixture(devbox: 8, jhanf: 1)

    {out, status} = run_check(ps, "devbox", [{"CASEIN_AGENT_MAX_PER_USER", "8"}])
    assert status == 75, out
    assert out =~ "devbox already runs 8 agents (limit 8)"

    # Another user is not blocked by devbox's count.
    {out, status} = run_check(ps, "jhanf", [{"CASEIN_AGENT_MAX_PER_USER", "8"}])
    assert status == 0, out
  end

  test "counts every agent binary form, including codex under node" do
    ps = """
    devbox 101 1 /usr/local/bin/opencode
    devbox 102 1 /home/devbox/.local/bin/claude.exe --resume
    devbox 103 1 claude_exe
    devbox 104 1 /usr/bin/node /home/devbox/.local/lib/node_modules/@openai/codex/bin/codex.js
    devbox 105 1 /opt/grok/grok --sandbox x
    devbox 106 1 /usr/bin/node /srv/app/server.js
    devbox 107 1 bash
    devbox 108 1 /usr/bin/vim claude.md
    """

    {out, status} = run_check(ps, "devbox", [{"CASEIN_AGENT_MAX_PER_USER", "5"}])
    assert status == 75, out
    assert out =~ "devbox already runs 5 agents (limit 5)"
  end

  test "a codex wrapper and the native binary it execs are one agent" do
    # The npm `codex` entry point is node; it execs the vendored native binary
    # as its child. Counting both spent two slots per Codex pane and refused
    # launches on a box that was under budget.
    ps = """
    devbox 200 1 /usr/bin/node /home/devbox/.local/bin/codex --model x
    devbox 201 200 /home/devbox/.local/lib/node_modules/@openai/codex/vendor/bin/codex --model x
    devbox 202 1 /usr/local/bin/opencode
    """

    {out, status} = run_check(ps, "devbox", [{"CASEIN_AGENT_MAX_PER_USER", "3"}])
    assert status == 0, out
    refute out =~ "refused:budget"

    # ...and two really are two.
    {out, status} = run_check(ps, "devbox", [{"CASEIN_AGENT_MAX_PER_USER", "2"}])
    assert status == 75, out
    assert out =~ "devbox already runs 2 agents (limit 2)"
  end

  test "a limit of 0 disables that limit" do
    ps = ps_fixture(devbox: 50)

    {out, status} =
      run_check(ps, "devbox", [
        {"CASEIN_AGENT_MAX_TOTAL", "0"},
        {"CASEIN_AGENT_MAX_PER_USER", "0"}
      ])

    assert status == 0, out
  end

  test "CASEIN_AGENT_BUDGET_FORCE=1 overrides with a loud warning and a distinct token" do
    ps = ps_fixture(devbox: 30)

    {out, status} = run_check(ps, "devbox", [{"CASEIN_AGENT_BUDGET_FORCE", "1"}])
    assert status == 0, out
    assert out =~ "agent budget exceeded"
    assert out =~ ~r/^proceed:budget-force$/m
    refute out =~ "budget exhausted"
    refute out =~ "refused:budget"
  end

  test "non-integer limits are a misconfiguration, not a refusal" do
    ps = ps_fixture(devbox: 1)

    {out, status} = run_check(ps, "devbox", [{"CASEIN_AGENT_MAX_TOTAL", "lots"}])
    assert status == 2, out
    assert out =~ "CASEIN_AGENT_MAX_TOTAL must be an integer"
  end

  test "an unreadable process list is a misconfiguration" do
    tmp = tmp!()

    {out, status} =
      System.cmd(
        "bash",
        ["-c", "source #{@helper}; agent_budget_check claude"],
        env: [
          {"CASEIN_AGENT_BUDGET_PS_PATH", Path.join(tmp, "missing")},
          {"CASEIN_AGENT_BUDGET_USER", "devbox"}
        ],
        stderr_to_stdout: true
      )

    assert status == 2, out
    assert out =~ "cannot read process list"
  end

  defp ps_fixture(counts) do
    counts
    |> Enum.flat_map(fn {user, n} -> for i <- 1..n, do: {user, i} end)
    |> Enum.with_index(100)
    |> Enum.map_join("", fn {{user, i}, pid} ->
      bin = Enum.at(~w(opencode claude codex grok), rem(i, 4))
      # ppid 1 — every fixture row is its own session, never a wrapper's child.
      "#{user} #{pid} 1 /usr/local/bin/#{bin} --task #{i}\n"
    end)
  end

  defp run_check(ps_contents, user, extra_env) do
    tmp = tmp!()
    ps_path = Path.join(tmp, "ps")
    File.write!(ps_path, ps_contents)

    System.cmd(
      "bash",
      ["-c", "source #{@helper}; agent_budget_check claude"],
      env:
        [
          {"CASEIN_AGENT_BUDGET_PS_PATH", ps_path},
          {"CASEIN_AGENT_BUDGET_USER", user},
          {"CASEIN_AGENT_MAX_TOTAL", "24"},
          {"CASEIN_AGENT_MAX_PER_USER", "8"},
          {"CASEIN_AGENT_BUDGET_FORCE", "0"}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp tmp! do
    dir = Path.join(System.tmp_dir!(), "agent-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
