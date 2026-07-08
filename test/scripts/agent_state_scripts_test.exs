defmodule Scripts.AgentStateScriptsTest do
  @moduledoc """
  Coverage for the fire-and-forget agent-state reporter scripts.

  The scripts call an unqualified `curl`, so tests stub it on PATH and assert
  on the captured request body instead of standing up an HTTP server. The
  state script reads stdin with `cat`, which never sees EOF under
  `System.cmd/3`'s port stdin — mapping tests pipe through `sh -c` instead.
  """
  use ExUnit.Case, async: true

  @state_script Path.expand("../../scripts/devide-agent-state.sh", __DIR__)
  @codex_script Path.expand("../../scripts/devide-codex-notify.sh", __DIR__)
  @grok_hook Path.expand(
               "../../scripts/agent-hooks/grok-devide-agent-state.json",
               __DIR__
             )

  @grok_events ~w(SessionStart UserPromptSubmit PreToolUse Notification Stop StopFailure SessionEnd)

  test "scripts have valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @state_script])
    assert {_, 0} = System.cmd("bash", ["-n", @codex_script])
  end

  test "grok hook file wires every lifecycle event to the env-guarded state script" do
    hooks = @grok_hook |> File.read!() |> Jason.decode!() |> Map.fetch!("hooks")

    for event <- @grok_events do
      assert [%{"hooks" => [%{"type" => "command", "command" => command, "timeout" => 5}]}] =
               Map.fetch!(hooks, event)

      assert command =~ "devide-agent-state.sh"
      assert command =~ ~s([ -n "${DEVIDE_AGENT_MCP_HOME:-}" ] || exit 0)
    end
  end

  test "state script exits 0 and stays silent without DevIDE env" do
    assert {"", 0} =
             System.cmd("bash", [@state_script],
               env: [
                 {"DEV_IDE_API_TOKEN", nil},
                 {"DEVIDE_WORKSPACE_ID", nil},
                 {"DEVIDE_TERMINAL_MCP_URL", nil},
                 {"TMUX_PANE", nil}
               ],
               stderr_to_stdout: true
             )
  end

  test "grok stop event reports done via GROK_HOOK_EVENT" do
    body = run_state_script(%{"GROK_HOOK_EVENT" => "stop"})

    assert body =~ ~s("state": "done")
    assert body =~ ~s("pane": "%9")
    assert body =~ ~s("source": "hook")
    assert body =~ "terminal_report_agent_state"
  end

  test "grok stop_failure reports blocked" do
    body = run_state_script(%{"GROK_HOOK_EVENT" => "stop_failure"})

    assert body =~ ~s("state": "blocked")
  end

  test "claude Stop payload on stdin still reports done" do
    body = run_state_script(%{}, ~s({"hook_event_name": "Stop"}))

    assert body =~ ~s("state": "done")
  end

  test "unmapped events report nothing" do
    refute run_state_script(%{"GROK_HOOK_EVENT" => "post_tool_use"})
  end

  test "codex agent-turn-complete reports done with the last assistant message" do
    notification =
      Jason.encode!(%{
        "type" => "agent-turn-complete",
        "turn-id" => "t1",
        "last-assistant-message" => "All tests pass."
      })

    body = run_codex_script([notification])

    assert body =~ ~s("state": "done")
    assert body =~ ~s("message": "All tests pass.")
    assert body =~ ~s("pane": "%9")
  end

  test "codex ignores other notification types" do
    refute run_codex_script([Jason.encode!(%{"type" => "something-else"})])
  end

  test "codex exits 0 without DevIDE env" do
    assert {"", 0} =
             System.cmd("bash", [@codex_script, "{}"],
               env: [
                 {"DEV_IDE_API_TOKEN", nil},
                 {"DEVIDE_WORKSPACE_ID", nil},
                 {"DEVIDE_TERMINAL_MCP_URL", nil},
                 {"TMUX_PANE", nil}
               ],
               stderr_to_stdout: true
             )
  end

  # Runs the state script with stubbed curl; returns the captured request
  # body, or nil when the script never invoked curl.
  defp run_state_script(extra_env, stdin \\ "") do
    {dir, capture} = stub_curl!()

    env =
      base_env(dir, capture) ++
        Enum.map(extra_env, fn {k, v} -> {k, v} end) ++
        [{"HOOK_STDIN", stdin}, {"STATE_SCRIPT", @state_script}]

    {out, 0} =
      System.cmd("sh", ["-c", ~s(printf '%s' "$HOOK_STDIN" | bash "$STATE_SCRIPT")],
        env: env,
        stderr_to_stdout: true
      )

    assert out == ""
    read_capture(capture)
  end

  defp run_codex_script(args) do
    {dir, capture} = stub_curl!()

    {out, 0} =
      System.cmd("bash", [@codex_script | args],
        env: base_env(dir, capture),
        stderr_to_stdout: true
      )

    assert out == ""
    read_capture(capture)
  end

  defp base_env(stub_dir, capture) do
    [
      {"PATH", stub_dir <> ":" <> System.get_env("PATH")},
      {"CURL_CAPTURE", capture},
      {"DEV_IDE_API_TOKEN", "test-token"},
      {"DEVIDE_WORKSPACE_ID", "ws-test"},
      {"DEVIDE_TERMINAL_MCP_URL", "http://127.0.0.1:1/api/terminals/mcp"},
      {"TMUX_PANE", "%9"},
      {"DEVIDE_AGENT_MCP_HOME", stub_dir},
      {"GROK_HOOK_EVENT", nil}
    ]
  end

  defp stub_curl!() do
    dir =
      Path.join(
        System.tmp_dir!(),
        "agent-state-scripts-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    curl = Path.join(dir, "curl")
    File.write!(curl, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CURL_CAPTURE\"\n")
    File.chmod!(curl, 0o755)

    {dir, Path.join(dir, "curl-args")}
  end

  defp read_capture(capture) do
    case File.read(capture) do
      {:ok, body} -> body
      _ -> nil
    end
  end
end
