defmodule Scripts.AgentStateScriptsTest do
  @moduledoc """
  Coverage for the fire-and-forget agent-state reporter scripts.

  The scripts call an unqualified `curl`, so tests stub it on PATH and assert
  on the captured request body instead of standing up an HTTP server. The
  state script reads stdin with `cat`, which never sees EOF under
  `System.cmd/3`'s port stdin — mapping tests pipe through `sh -c` instead.
  """
  use ExUnit.Case, async: true

  @state_script Path.expand("../../scripts/casein-agent-state.sh", __DIR__)
  @codex_script Path.expand("../../scripts/casein-codex-notify.sh", __DIR__)
  @priv_state_script Path.expand("../../priv/scripts/casein-agent-state.sh", __DIR__)
  @priv_codex_script Path.expand("../../priv/scripts/casein-codex-notify.sh", __DIR__)
  @grok_hook Path.expand(
               "../../scripts/agent-hooks/grok-casein-agent-state.json",
               __DIR__
             )

  @grok_events ~w(SessionStart UserPromptSubmit PreToolUse Notification Stop StopFailure SessionEnd)

  test "scripts have valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @state_script])
    assert {_, 0} = System.cmd("bash", ["-n", @codex_script])
  end

  test "release hook copies stay in parity with the source hooks" do
    assert File.read!(@priv_state_script) == File.read!(@state_script)
    assert File.read!(@priv_codex_script) == File.read!(@codex_script)
  end

  test "grok hook file wires every lifecycle event to the env-guarded state script" do
    hooks = @grok_hook |> File.read!() |> Jason.decode!() |> Map.fetch!("hooks")

    for event <- @grok_events do
      assert [%{"hooks" => [%{"type" => "command", "command" => command, "timeout" => 5}]}] =
               Map.fetch!(hooks, event)

      assert command =~ "casein-agent-state.sh"
      assert command =~ "GROK_PLUGIN_ROOT"
      assert command =~ ~s([ -n "${CASEIN_AGENT_MCP_HOME:-}" ] || exit 0)
    end
  end

  test "state script exits 0 and stays silent without Casein env" do
    assert {"", 0} =
             System.cmd("bash", [@state_script],
               env: [
                 {"CASEIN_API_TOKEN", nil},
                 {"CASEIN_WORKSPACE_ID", nil},
                 {"CASEIN_TERMINAL_MCP_URL", nil},
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

  test "grok hook payload reports camelCase transcript and session metadata" do
    payload =
      Jason.encode!(%{
        "hookEventName" => "Stop",
        "transcriptPath" => "/home/devbox/.grok/sessions/2026/07/updates.jsonl",
        "sessionId" => "grok-session-123"
      })

    body = run_state_script(%{}, payload)

    assert body =~ ~s("transcript_path": "/home/devbox/.grok/sessions/2026/07/updates.jsonl")
    assert body =~ ~s("agent_session_id": "grok-session-123")
  end

  test "grok stop_failure reports blocked" do
    body = run_state_script(%{"GROK_HOOK_EVENT" => "stop_failure"})

    assert body =~ ~s("state": "blocked")
  end

  test "Grok bootstrap reports private leader and capability bundle metadata" do
    digest = String.duplicate("a", 64)

    body =
      run_state_script(%{
        "GROK_HOOK_EVENT" => "session_start",
        "CASEIN_AGENT_LAUNCH_CONTEXT" => "grok",
        "CASEIN_GROK_LEADER_SOCKET" => "/tmp/casein-grok-leaders-test/abc.sock",
        "CASEIN_GROK_BUNDLE_DIR" => "/tmp/grok-bundles/sha256-#{digest}",
        "CASEIN_GROK_BUNDLE_DIGEST" => digest
      })

    assert body =~ ~s("agent_runtime": "grok")
    assert body =~ ~s("grok_leader_socket": "/tmp/casein-grok-leaders-test/abc.sock")
    assert body =~ ~s("grok_bundle_digest": "#{digest}")
  end

  test "claude Stop payload on stdin still reports done" do
    body = run_state_script(%{}, ~s({"hook_event_name": "Stop"}))

    assert body =~ ~s("state": "done")
  end

  test "long-lived legacy pane reports through rematerialized hook" do
    body =
      run_state_script(
        %{
          "CASEIN_WORKSPACE_ID" => nil,
          "CASEIN_TERMINAL_MCP_URL" => nil,
          "CASEIN_AGENT_MCP_HOME" => nil,
          "CASEIN_AGENT_LAUNCH_CONTEXT" => nil,
          "DEVIDE_WORKSPACE_ID" => "ws-legacy",
          "DEVIDE_TERMINAL_MCP_URL" => "http://127.0.0.1:1/api/terminals/mcp",
          "DEVIDE_AGENT_MCP_HOME" => System.tmp_dir!(),
          "DEVIDE_AGENT_LAUNCH_CONTEXT" => "claude"
        },
        ~s({"hook_event_name": "Stop"})
      )

    assert body =~ ~s("workspace_id": "ws-legacy")
    assert body =~ ~s("agent_runtime": "claude")
  end

  test "unmapped events report nothing" do
    refute run_state_script(%{"GROK_HOOK_EVENT" => "post_tool_use"})
  end

  test "startup Notification banners report idle, not blocked" do
    body =
      run_state_script(
        %{},
        ~s({"hook_event_name": "Notification", "message": "Claude Code login successful"})
      )

    assert body =~ ~s("state": "idle")
    refute body =~ "login successful"
    refute body =~ ~s("state": "blocked")
  end

  test "permission Notification still reports blocked" do
    body =
      run_state_script(
        %{},
        ~s({"hook_event_name": "Notification", "message": "needs permission to edit"})
      )

    assert body =~ ~s("state": "blocked")
    assert body =~ "needs permission to edit"
  end

  test "codex legacy notify forwards the canonical event to the workspace hook receiver" do
    notification =
      Jason.encode!(%{
        "type" => "agent-turn-complete",
        "thread-id" => "thread-legacy",
        "turn-id" => "t1",
        "last-assistant-message" => "All tests pass."
      })

    body = run_codex_script([notification])

    assert body =~ "/api/workspaces/ws-test/codex/hooks"
    assert body =~ ~s("transport":"notify")
    assert body =~ ~s("type":"agent-turn-complete")
    assert body =~ ~s("thread-id":"thread-legacy")
    assert body =~ ~s("last-assistant-message":"All tests pass.")
    assert body =~ ~s("pane":"%9")
  end

  test "codex forwards new hook types without requiring a script update" do
    body = run_codex_script([Jason.encode!(%{"type" => "something-else"})])

    assert body =~ ~s("type":"something-else")
  end

  test "codex lifecycle hooks read JSON from stdin" do
    body =
      run_codex_stdin(
        Jason.encode!(%{
          "hook_event_name" => "PermissionRequest",
          "session_id" => "thread-1",
          "reason" => "Network access"
        })
      )

    assert body =~ ~s("transport":"hook")
    assert body =~ ~s("hook_event_name":"PermissionRequest")
    assert body =~ ~s("reason":"Network access")
  end

  test "codex prompt hooks set a bounded task-oriented tmux pane title" do
    {dir, capture} = stub_curl!()
    tmux_capture = Path.join(dir, "tmux-args")
    prompt = String.duplicate("Ship polished Codex parity ", 8)

    env =
      base_env(dir, capture) ++
        [
          {"HOOK_STDIN",
           Jason.encode!(%{"hook_event_name" => "UserPromptSubmit", "prompt" => prompt})},
          {"CODEX_SCRIPT", @codex_script},
          {"TMUX_CAPTURE", tmux_capture}
        ]

    assert {"", 0} =
             System.cmd("sh", ["-c", ~s(printf '%s' "$HOOK_STDIN" | bash "$CODEX_SCRIPT")],
               env: env,
               stderr_to_stdout: true
             )

    title_args = File.read!(tmux_capture)
    assert title_args =~ "select-pane -t %9 -T Ship polished Codex parity"
    assert byte_size(String.trim(title_args)) <= 110
  end

  test "codex exits 0 without Casein env" do
    assert {"", 0} =
             System.cmd("bash", [@codex_script, "{}"],
               env: [
                 {"CASEIN_API_TOKEN", nil},
                 {"CASEIN_WORKSPACE_ID", nil},
                 {"CASEIN_TERMINAL_MCP_URL", nil},
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

  defp run_codex_stdin(stdin) do
    {dir, capture} = stub_curl!()

    env =
      base_env(dir, capture) ++
        [{"HOOK_STDIN", stdin}, {"CODEX_SCRIPT", @codex_script}]

    {out, 0} =
      System.cmd("sh", ["-c", ~s(printf '%s' "$HOOK_STDIN" | bash "$CODEX_SCRIPT")],
        env: env,
        stderr_to_stdout: true
      )

    assert out == ""
    read_capture(capture)
  end

  defp base_env(stub_dir, capture) do
    [
      {"PATH", stub_dir <> ":" <> System.get_env("PATH")},
      {"CURL_CAPTURE", capture},
      {"CASEIN_API_TOKEN", "test-token"},
      {"CASEIN_WORKSPACE_ID", "ws-test"},
      {"CASEIN_TERMINAL_MCP_URL", "http://127.0.0.1:1/api/terminals/mcp"},
      {"TMUX_PANE", "%9"},
      {"CASEIN_AGENT_MCP_HOME", stub_dir},
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

    tmux = Path.join(dir, "tmux")
    File.write!(tmux, "#!/bin/sh\nprintf '%s ' \"$@\" > \"$TMUX_CAPTURE\"\n")
    File.chmod!(tmux, 0o755)

    {dir, Path.join(dir, "curl-args")}
  end

  defp read_capture(capture) do
    case File.read(capture) do
      {:ok, body} -> body
      _ -> nil
    end
  end
end
