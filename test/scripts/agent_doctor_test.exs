defmodule Scripts.AgentDoctorTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/lib/agent-doctor.sh", __DIR__)
  @bundle_script Path.expand("../../scripts/lib/grok-capability-bundle.py", __DIR__)
  @leader_runtime Path.expand("../../scripts/lib/grok-leader-runtime.py", __DIR__)
  @runtimes ~w(grok claude codex opencode agent devide)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "devide-agent-doctor-#{System.unique_integer([:positive, :monotonic])}"
      )

    home = Path.join(root, "home")
    cwd = Path.join(root, "project")
    remove_test_root(root)
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)
    on_exit(fn -> remove_test_root(root) end)

    %{home: home, cwd: cwd}
  end

  test "plain shells keep installed launcher shims off PATH without failing", %{
    home: home,
    cwd: cwd
  } do
    install_mock_shims(home)

    {output, 0} =
      run_function(home, cwd, """
      check_shims
      printf 'COUNTS pass=%s warn=%s fail=%s\n' "$PASS" "$WARN" "$FAIL"
      """)

    assert output =~ "plain-shell PATH intentionally excludes #{home}/.casein/agent-shims"
    assert output =~ "COUNTS pass="
    assert output =~ "fail=0"
    refute output =~ "FAIL "
  end

  test "managed launch contexts fail when launcher shims do not win PATH", %{
    home: home,
    cwd: cwd
  } do
    install_mock_shims(home)
    shadow_dir = install_mock_shadow_bins(home)

    {output, 0} =
      run_function(
        home,
        cwd,
        """
        DEVIDE_AGENT_LAUNCH_CONTEXT=grok
        check_shims
        printf 'COUNTS pass=%s warn=%s fail=%s\n' "$PASS" "$WARN" "$FAIL"
        """,
        [{"PATH", "#{shadow_dir}:/usr/bin:/bin"}]
      )

    assert output =~ "FAIL shim shadowed: grok resolves to"
    assert output =~ "FAIL paired-context PATH missing #{home}/.casein/agent-shims"
    refute output =~ "fail=0"
  end

  test "managed Grok verifies its immutable bundle and private leader without a project MCP file",
       %{home: home, cwd: cwd} do
    bundle = build_bundle!(home)
    leader = listen_unix_socket!(home)

    server_names = [
      "devide-terminal-demo-workspace",
      "devide-preview-demo-workspace",
      "devide-artifact-demo-workspace"
    ]

    inspect_json =
      Jason.encode!(%{
        "grokVersion" => "0.2.93",
        "cwd" => cwd,
        "headers" => %{"Authorization" => "Bearer never-print-this-token"},
        # Session pluginDirs are negotiated by ACP, so a standalone inspect
        # process is not expected to expose them.
        "mcpServers" => []
      })

    install_mock_grok(home, inspect_json)

    {output, 0} =
      run_function(
        home,
        cwd,
        """
        check_grok_runtime
        printf 'COUNTS pass=%s warn=%s fail=%s\n' "$PASS" "$WARN" "$FAIL"
        """,
        [
          {"DEVIDE_WORKSPACE_NAME", "Demo Workspace"},
          {"DEVIDE_WORKSPACE_ID", "workspace-123"},
          {"DEVIDE_AGENT_LAUNCH_CONTEXT", "grok"},
          {"DEVIDE_GROK_BUNDLE_ROOT", bundle.root},
          {"DEVIDE_GROK_BUNDLE_DIR", bundle.dir},
          {"DEVIDE_GROK_BUNDLE_DIGEST", bundle.digest},
          {"DEVIDE_GROK_LEADER_ROOT", leader.root},
          {"DEVIDE_GROK_LEADER_SOCKET", leader.socket},
          {"DEVIDE_GROK_PROVIDER_AUTH_MODE", "api-key"},
          {"CASEIN_API_TOKEN", "never-print-this-token"}
        ]
      )

    refute File.exists?(Path.join(cwd, ".mcp.json"))
    assert output =~ "Grok capability bundle verified (digest sha256-#{bundle.digest})"
    assert output =~ "Grok private leader socket is active and healthy"
    assert output =~ "Grok managed provider auth is durable"
    assert output =~ "Grok inspect resolved version 0.2.93"
    assert output =~ "standalone Grok inspect does not expose 3 session-scoped"

    for server_name <- server_names do
      assert output =~ "Grok MCP handshake healthy: #{server_name}"
    end

    assert output =~ "fail=0"
    refute output =~ "never-print-this-token"
    refute output =~ "global Grok config"
  end

  test "managed Grok diagnostics report isolated renewable OAuth without exposing credentials",
       %{home: home, cwd: cwd} do
    bundle = build_bundle!(home)
    leader = listen_unix_socket!(home)

    install_mock_grok(
      home,
      Jason.encode!(%{"grokVersion" => "0.2.93", "cwd" => cwd, "mcpServers" => []})
    )

    {output, 0} =
      run_function(
        home,
        cwd,
        "check_grok_runtime",
        [
          {"DEVIDE_AGENT_LAUNCH_CONTEXT", "grok"},
          {"DEVIDE_GROK_BUNDLE_ROOT", bundle.root},
          {"DEVIDE_GROK_BUNDLE_DIR", bundle.dir},
          {"DEVIDE_GROK_BUNDLE_DIGEST", bundle.digest},
          {"DEVIDE_GROK_LEADER_ROOT", leader.root},
          {"DEVIDE_GROK_LEADER_SOCKET", leader.socket},
          {"DEVIDE_GROK_PROVIDER_AUTH_MODE", "oauth-inline-refresh"}
        ]
      )

    assert output =~ "isolated refreshable OAuth (in-memory renewal)"
  end

  test "Grok diagnostics distinguish a plain shell from a broken managed launch", %{
    home: home,
    cwd: cwd
  } do
    inspect_json = Jason.encode!(%{"grokVersion" => "0.2.93", "cwd" => cwd, "mcpServers" => []})
    install_mock_grok(home, inspect_json)

    {output, 0} =
      run_function(
        home,
        cwd,
        """
        check_grok_runtime
        printf 'COUNTS pass=%s warn=%s fail=%s\n' "$PASS" "$WARN" "$FAIL"
        """,
        [
          {"DEVIDE_WORKSPACE_NAME", "Demo Workspace"},
          {"DEVIDE_WORKSPACE_ID", "workspace-123"}
        ]
      )

    assert output =~ "no session-scoped Grok capability bundle is active"
    assert output =~ "no private Grok leader socket is active"
    assert output =~ "fail=0"

    {managed_output, 0} =
      run_function(
        home,
        cwd,
        """
        check_grok_runtime
        printf 'COUNTS pass=%s warn=%s fail=%s\n' "$PASS" "$WARN" "$FAIL"
        """,
        [
          {"DEVIDE_AGENT_LAUNCH_CONTEXT", "grok"},
          {"DEVIDE_WORKSPACE_NAME", "Demo Workspace"},
          {"DEVIDE_WORKSPACE_ID", "workspace-123"}
        ]
      )

    assert managed_output =~
             "FAIL Grok managed launch is missing DEVIDE_GROK_BUNDLE_DIR and DEVIDE_GROK_BUNDLE_DIGEST"

    assert managed_output =~ "FAIL Grok managed launch is missing DEVIDE_GROK_LEADER_SOCKET"
    refute managed_output =~ "fail=0"
  end

  test "Grok diagnostics reject a mutable bundle and redact probe output", %{
    home: home,
    cwd: cwd
  } do
    bundle = build_bundle!(home)
    leader = listen_unix_socket!(home)
    File.chmod!(Path.join(bundle.dir, ".mcp.json"), 0o644)

    inspect_json =
      Jason.encode!(%{
        "grokVersion" => "0.2.93",
        "cwd" => cwd,
        "mcpServers" => []
      })

    install_mock_grok(home, inspect_json)

    {output, 0} =
      run_function(
        home,
        cwd,
        """
        check_grok_runtime
        printf 'COUNTS pass=%s warn=%s fail=%s\n' "$PASS" "$WARN" "$FAIL"
        """,
        [
          {"DEVIDE_WORKSPACE_NAME", "Demo Workspace"},
          {"DEVIDE_WORKSPACE_ID", "workspace-123"},
          {"DEVIDE_AGENT_LAUNCH_CONTEXT", "grok"},
          {"DEVIDE_GROK_BUNDLE_ROOT", bundle.root},
          {"DEVIDE_GROK_BUNDLE_DIR", bundle.dir},
          {"DEVIDE_GROK_BUNDLE_DIGEST", bundle.digest},
          {"DEVIDE_GROK_LEADER_ROOT", leader.root},
          {"DEVIDE_GROK_LEADER_SOCKET", leader.socket},
          {"CASEIN_API_TOKEN", "never-print-this-token"}
        ]
      )

    assert output =~ "FAIL Grok capability bundle failed immutable digest verification"
    refute output =~ "fail=0"
    refute output =~ "never-print-this-token"
  end

  defp build_bundle!(home) do
    fixture_dir = Path.join(home, "bundle-fixtures")
    bundle_root = Path.join(home, ".casein/grok-bundles")
    mcp_file = Path.join(fixture_dir, "mcp.json")
    File.mkdir_p!(fixture_dir)
    File.write!(mcp_file, ~s({"mcpServers":{}}\n))

    {output, 0} =
      System.cmd(
        "python3",
        [
          @bundle_script,
          "build",
          "--bundle-root",
          bundle_root,
          "--mcp-config",
          mcp_file,
          "--hooks-disabled"
        ],
        stderr_to_stdout: true
      )

    [dir, digest] = String.split(output, "\n", trim: true)
    %{root: bundle_root, dir: dir, digest: digest}
  end

  defp listen_unix_socket!(home) do
    base = Path.join(home, ".casein/grok-leaders")
    root = Path.join(base, String.duplicate("a", 24))
    socket = Path.join(root, "leader.sock")
    metadata = Path.join(root, ".devide-launcher")
    log = Path.join(base, "fake-leader.log")
    server = Path.join(base, "fake-leader.py")
    File.mkdir_p!(root)
    File.chmod!(base, 0o700)
    File.chmod!(root, 0o700)

    File.write!(server, """
    import json, socket, struct, sys
    server = socket.socket(socket.AF_UNIX)
    server.bind(sys.argv[1])
    server.listen(8)
    while True:
        client, _ = server.accept()
        try:
            header = client.recv(4)
            if len(header) != 4:
                continue
            size = struct.unpack(">I", header)[0]
            data = b""
            while len(data) < size:
                data += client.recv(size - len(data))
            assert json.loads(data)["type"] == "register"
            payload = json.dumps({"type": "registered", "ready": True}).encode()
            client.sendall(struct.pack(">I", len(payload)) + payload)
            disconnect_size = struct.unpack(">I", client.recv(4))[0]
            client.recv(disconnect_size)
        finally:
            client.close()
    """)

    assert {output, 0} =
             System.cmd(
               "python3",
               [@leader_runtime, "spawn", metadata, log, "python3", server, socket],
               stderr_to_stdout: true
             )

    pid = output |> String.trim() |> String.to_integer()
    on_exit(fn -> System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true) end)

    assert Enum.any?(1..100, fn _attempt -> leader_probe_healthy?(socket, pid) end)
    %{root: root, socket: socket}
  end

  defp leader_probe_healthy?(socket, pid) do
    match?(
      {_, 0},
      System.cmd(
        "python3",
        [@leader_runtime, "probe", socket, Integer.to_string(pid), "1"],
        stderr_to_stdout: true
      )
    )
  end

  defp install_mock_shims(home) do
    shim_dir = Path.join(home, ".casein/agent-shims")
    File.mkdir_p!(shim_dir)

    for runtime <- @runtimes do
      path = Path.join(shim_dir, runtime)
      File.write!(path, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(path, 0o755)
    end
  end

  defp install_mock_shadow_bins(home) do
    bin_dir = Path.join(home, "shadow-bin")
    File.mkdir_p!(bin_dir)

    for runtime <- @runtimes do
      path = Path.join(bin_dir, runtime)
      File.write!(path, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    bin_dir
  end

  defp install_mock_grok(home, inspect_json) do
    real_bin_dir = Path.join(home, ".casein/real-bins")
    File.mkdir_p!(real_bin_dir)
    grok = Path.join(real_bin_dir, "grok")

    File.write!(
      grok,
      """
      #!/usr/bin/env bash
      set -euo pipefail
      if [[ "${1:-}" == "--leader-socket" && "${3:-}:${4:-}:${5:-}" == "leader:info:--json" ]]; then
        printf '%s\n' '{"status":"ready","sessionId":"redacted-session"}'
        printf '%s\n' 'mock leader stderr contains never-print-this-token' >&2
        exit 0
      fi
      case "${1:-}:${2:-}:${3:-}" in
        inspect:--help:)
          printf '%s\n' 'Usage: grok inspect --json'
          ;;
        inspect:--json:)
          printf '%s\n' #{shell_quote(inspect_json)}
          printf '%s\n' 'mock stderr contains never-print-this-token' >&2
          ;;
        mcp:doctor:--help)
          printf '%s\n' 'Usage: grok mcp doctor --json NAME'
          ;;
        mcp:doctor:--json)
          printf '{"servers":[{"name":"%s","healthy":true,"checks":[{"label":"7 tools discovered","passed":true}]}]}\n' "$4"
          printf '%s\n' 'mock stderr contains never-print-this-token' >&2
          ;;
        *)
          exit 64
          ;;
      esac
      """
    )

    File.chmod!(grok, 0o755)
  end

  defp run_function(home, cwd, body, extra_env \\ []) do
    command = """
    set -euo pipefail
    source #{shell_quote(@script)}
    PASS=0
    WARN=0
    FAIL=0
    #{body}
    """

    base_env = [
      {"HOME", home},
      {"PATH", "/usr/bin:/bin"},
      {"TMUX", ""},
      {"DEVIDE_AGENT_LAUNCH_CONTEXT", ""},
      {"DEVIDE_WORKTREE", ""},
      {"DEVIDE_WORKSPACE_NAME", ""},
      {"DEVIDE_WORKSPACE_ID", ""},
      {"CASEIN_API_TOKEN", ""},
      {"DEVIDE_GROK_BUNDLE_ROOT", ""},
      {"DEVIDE_GROK_BUNDLE_DIR", ""},
      {"DEVIDE_GROK_BUNDLE_DIGEST", ""},
      {"DEVIDE_GROK_LEADER_ROOT", ""},
      {"DEVIDE_GROK_LEADER_SOCKET", ""}
    ]

    System.cmd("bash", ["-c", command],
      cd: cwd,
      env: Map.merge(Map.new(base_env), Map.new(extra_env)) |> Enum.to_list(),
      stderr_to_stdout: true
    )
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp remove_test_root(root) do
    if File.exists?(root) do
      _ = System.cmd("chmod", ["-R", "u+w", root], stderr_to_stdout: true)
      File.rm_rf!(root)
    end
  end
end
