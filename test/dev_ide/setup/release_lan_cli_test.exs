defmodule DevIDE.Setup.ReleaseLanCliTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../rel/overlays/bin/devide", __DIR__)

  test "release LAN CLI has valid shell syntax" do
    assert {_, 0} = System.cmd("sh", ["-n", @script])
  end

  test "release LAN CLI help is runnable without Mix" do
    assert {out, 0} = System.cmd(@script, ["--help"])

    assert out =~ "devide lan up"
    assert out =~ "devide lan status"
  end

  test "release LAN CLI help runs from a clean release directory" do
    fixture = release_fixture()

    assert {out, 0} = run_cli(fixture, ["--help"], cd: "/")

    assert out =~ "devide lan up"
    assert out =~ "devide lan down"
  end

  test "release LAN CLI installs a managed backend and HTTP edge" do
    text = File.read!(@script)

    assert text =~ "BACKEND_SERVICE=\"devide-lan.service\""
    assert text =~ "EDGE_SOCKET=\"devide-lan-http-edge.socket\""
    assert text =~ "append_env_if_missing DEV_IDE_LAN_INSECURE_HTTP true"
    assert text =~ "INSTALL_RELEASE_DIR"
    assert text =~ "ExecStart=${LAN_APP_BIN} start"
    assert text =~ "ExecStart=${proxy} 127.0.0.1:${PORT}"
    assert text =~ "ensure_release_static_assets"
    assert text =~ "READY     ${canonical_url}"
  end

  test "install preserves env overrides while refreshing unit files" do
    fixture = release_fixture()

    File.mkdir_p!(Path.dirname(fixture.env_file))

    File.write!(fixture.env_file, """
    PORT='4010'
    DEV_IDE_LAN_HOST='devide.home.arpa'
    DEV_IDE_LAN_INSECURE_HTTP_PORT='8080'
    DEV_IDE_DEFAULT_WORKSPACE='custom'
    DEV_IDE_WORKSPACES_ROOT='#{fixture.workspace_root}'
    DATABASE_URL='ecto://custom'
    """)

    assert {out, 0} = run_cli(fixture, ["lan", "install"])

    assert out =~ "Installed DevIDE managed LAN units."
    assert out =~ "release:    #{fixture.install_release_dir}"
    assert out =~ "status env: #{fixture.public_env_file}"

    env = File.read!(fixture.env_file)
    assert count_lines(env, "PORT=") == 1
    assert count_lines(env, "DATABASE_URL=") == 1
    assert count_lines(env, "DATABASE_PATH=") == 1
    assert env =~ "PORT='4010'"
    assert env =~ "DATABASE_URL='ecto://custom'"
    assert env =~ "DATABASE_PATH='#{fixture.database_path}'"

    backend = File.read!(Path.join(fixture.unit_dir, "devide-lan.service"))
    socket = File.read!(Path.join(fixture.unit_dir, "devide-lan-http-edge.socket"))
    edge = File.read!(Path.join(fixture.unit_dir, "devide-lan-http-edge.service"))

    assert File.exists?(Path.join(fixture.install_release_dir, "bin/devide"))
    assert File.exists?(Path.join(fixture.install_release_dir, "bin/dev_ide"))
    assert File.exists?(Path.join(fixture.install_release_dir, "bin/migrate"))

    refute backend =~ fixture.release_dir
    assert backend =~ "WorkingDirectory=#{fixture.install_release_dir}"
    assert backend =~ "ExecStart=#{fixture.install_release_dir}/bin/dev_ide start"
    assert socket =~ "ListenStream=8080"
    assert edge =~ "ExecStart=#{fixture.fakebin}/systemd-socket-proxyd 127.0.0.1:4010"

    public_env = File.read!(fixture.public_env_file)
    assert public_env =~ "PORT='4010'"
    assert public_env =~ "DEV_IDE_LAN_HOST='devide.home.arpa'"
    assert public_env =~ "DEV_IDE_LAN_INSECURE_HTTP_PORT='8080'"
    assert public_env =~ "DATABASE_PATH='#{fixture.database_path}'"
    refute public_env =~ "DATABASE_URL"
    refute public_env =~ "SECRET_KEY_BASE"
    refute public_env =~ "DEV_IDE_API_TOKEN"
  end

  test "status works without private env access by using the public status env" do
    fixture = release_fixture()

    assert {_, 0} = run_cli(fixture, ["lan", "install"])
    File.chmod!(fixture.env_file, 0o000)

    assert {out, 0} = run_cli(fixture, ["lan", "status"])

    assert out =~ "READY     http://r630.local/"
    assert out =~ "INFO      using #{fixture.public_env_file}; #{fixture.env_file} is private"
    refute out =~ "WARN      #{fixture.env_file}"
  end

  test "up is idempotent across a partial install and reports ready after probes" do
    fixture = release_fixture()
    File.mkdir_p!(fixture.unit_dir)
    File.write!(Path.join(fixture.unit_dir, "devide-lan.service"), "stale unit\n")

    assert {out, 0} = run_cli(fixture, ["lan", "up"])

    assert out =~ "DevIDE Managed LAN status"
    assert out =~ "READY     http://r630.local/"
    assert out =~ "OK        devide-lan.service is active"
    assert out =~ "OK        http://r630.local/assets/css/app.css returned HTTP 200"
    assert out =~ "OK        http://192.168.1.240/ returned HTTP 302"

    backend = File.read!(Path.join(fixture.unit_dir, "devide-lan.service"))
    refute backend =~ "stale unit"

    log = File.read!(fixture.systemctl_log)
    assert log =~ "enable devide-lan.service"
    assert log =~ "restart devide-lan.service"
    assert log =~ "enable devide-lan-http-edge.socket"
    assert log =~ "restart devide-lan-http-edge.socket"
  end

  test "up reports a status block when the edge port cannot start" do
    fixture = release_fixture()

    assert {out, 1} =
             run_cli(fixture, ["lan", "up"],
               env: %{
                 "DEVIDE_FAKE_EDGE_ACTIVE" => "0",
                 "DEVIDE_FAKE_FAIL_RESTART" => "devide-lan-http-edge.socket"
               }
             )

    assert out =~ "error: failed to start devide-lan-http-edge.socket"
    assert out =~ "DevIDE Managed LAN status"
    assert out =~ "NOT READY http://r630.local/"
    assert out =~ "WARN      devide-lan-http-edge.socket is inactive"
    assert out =~ "Recent backend logs:"
  end

  test "status distinguishes a manual backend from managed readiness" do
    fixture = release_fixture()

    assert {out, 1} =
             run_cli(fixture, ["lan", "status"], env: %{"DEVIDE_FAKE_BACKEND_ACTIVE" => "0"})

    assert out =~ "NOT READY http://r630.local/"
    assert out =~ "OK        backend returned HTTP 302"

    assert out =~
             "INFO      manual backend detected; URL works but devide-lan.service is inactive"
  end

  test "status keeps the IP fallback visible when the local hostname fails" do
    fixture = release_fixture()

    assert {out, 1} =
             run_cli(fixture, ["lan", "status"], env: %{"DEVIDE_FAKE_CANONICAL_CODE" => "000"})

    assert out =~ "NOT READY http://r630.local/"
    assert out =~ "INFO      IP fallback http://192.168.1.240/"
    assert out =~ "WARN      http://r630.local/ probe failed"
    assert out =~ "OK        http://r630.local/assets/css/app.css returned HTTP 200"
    assert out =~ "OK        http://192.168.1.240/ returned HTTP 302"
  end

  test "install rejects release artifacts missing static assets" do
    fixture = release_fixture()
    File.rm!(Path.join(fixture.static_dir, "assets/css/app.css"))

    assert {out, 1} = run_cli(fixture, ["lan", "install"])

    assert out =~ "release is missing priv/static/assets/css/app.css"
    assert out =~ "mix assets.deploy before mix release"
  end

  test "down only stops managed systemd units" do
    fixture = release_fixture()

    assert {out, 0} = run_cli(fixture, ["lan", "down"])
    assert out =~ "Stopped DevIDE managed LAN."

    log = File.read!(fixture.systemctl_log)

    assert log =~ "disable --now devide-lan-http-edge.socket"
    assert log =~ "stop devide-lan-http-edge.service"
    assert log =~ "disable --now devide-lan.service"
    refute log =~ "kill"
    refute log =~ "pkill"
  end

  defp release_fixture do
    root =
      Path.join(System.tmp_dir!(), "devide-release-lan-cli-#{System.unique_integer([:positive])}")

    release_dir = Path.join(root, "release")
    bin_dir = Path.join(release_dir, "bin")
    fakebin = Path.join(root, "fakebin")
    unit_dir = Path.join(root, "systemd")
    env_file = Path.join(root, "etc/lan.env")
    public_env_file = Path.join(root, "etc/lan.public.env")
    database_path = Path.join(root, "var/lib/devide/lan/devide.sqlite3")
    workspace_root = Path.join(root, "workspaces")
    install_release_dir = Path.join(root, "opt/devide/lan-release")
    systemctl_log = Path.join(root, "systemctl.log")
    curl_log = Path.join(root, "curl.log")
    ufw_log = Path.join(root, "ufw.log")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(fakebin)

    File.cp!(@script, Path.join(bin_dir, "devide"))
    File.chmod!(Path.join(bin_dir, "devide"), 0o755)
    write_executable(Path.join(bin_dir, "dev_ide"), "#!/bin/sh\nexit 0\n")
    write_executable(Path.join(bin_dir, "migrate"), "#!/bin/sh\nexit 0\n")
    static_dir = Path.join(release_dir, "lib/dev_ide-0.1.0/priv/static")
    File.mkdir_p!(Path.join(static_dir, "assets/css"))
    File.mkdir_p!(Path.join(static_dir, "assets/js"))
    File.write!(Path.join(static_dir, "cache_manifest.json"), "{}\n")
    File.write!(Path.join(static_dir, "assets/css/app.css"), "body{}\n")
    File.write!(Path.join(static_dir, "assets/js/app.js"), "console.log('ok')\n")

    write_executable(Path.join(fakebin, "systemd-socket-proxyd"), "#!/bin/sh\nexit 0\n")
    write_executable(Path.join(fakebin, "chown"), "#!/bin/sh\nexit 0\n")

    write_executable(Path.join(fakebin, "ip"), """
    #!/bin/sh
    echo "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.240 uid 1000"
    """)

    write_executable(Path.join(fakebin, "journalctl"), """
    #!/bin/sh
    echo "journalctl $*" >> "$DEVIDE_FAKE_JOURNAL_LOG"
    echo "fake backend log"
    """)

    write_executable(Path.join(fakebin, "ufw"), """
    #!/bin/sh
    echo "$*" >> "$DEVIDE_FAKE_UFW_LOG"
    exit 0
    """)

    write_executable(Path.join(fakebin, "curl"), """
    #!/bin/sh
    last=""
    for arg in "$@"; do
      last="$arg"
    done
    echo "$last" >> "$DEVIDE_FAKE_CURL_LOG"
    case "$last" in
      *assets/css/app.css*) printf "%s" "${DEVIDE_FAKE_ASSET_CODE:-200}" ;;
      *127.0.0.1*) printf "%s" "${DEVIDE_FAKE_BACKEND_CODE:-302}" ;;
      *192.168.1.240*) printf "%s" "${DEVIDE_FAKE_IP_CODE:-302}" ;;
      *) printf "%s" "${DEVIDE_FAKE_CANONICAL_CODE:-302}" ;;
    esac
    exit 0
    """)

    write_executable(Path.join(fakebin, "systemctl"), """
    #!/bin/sh
    echo "$*" >> "$DEVIDE_FAKE_SYSTEMCTL_LOG"
    if [ "$1" = "is-active" ]; then
      case "$3" in
        devide-lan.service)
          [ "${DEVIDE_FAKE_BACKEND_ACTIVE:-1}" = "1" ]
          exit $?
          ;;
        devide-lan-http-edge.socket)
          [ "${DEVIDE_FAKE_EDGE_ACTIVE:-1}" = "1" ]
          exit $?
          ;;
        *)
          exit 1
          ;;
      esac
    fi

    if [ "$1" = "restart" ] && [ "${DEVIDE_FAKE_FAIL_RESTART:-}" = "$2" ]; then
      exit 1
    fi

    exit 0
    """)

    on_exit(fn -> File.rm_rf(root) end)

    user = System.get_env("USER") || String.trim(elem(System.cmd("id", ["-un"]), 0))

    env = %{
      "DEVIDE_LAN_REQUIRE_ROOT" => "false",
      "DEVIDE_LAN_ENV_FILE" => env_file,
      "DEVIDE_LAN_PUBLIC_ENV_FILE" => public_env_file,
      "DEVIDE_LAN_RELEASE_DIR" => install_release_dir,
      "DEVIDE_LAN_UNIT_DIR" => unit_dir,
      "DEVIDE_LAN_USER" => user,
      "DEVIDE_LAN_WORKSPACES_ROOT" => workspace_root,
      "DEVIDE_FAKE_SYSTEMCTL_LOG" => systemctl_log,
      "DEVIDE_FAKE_CURL_LOG" => curl_log,
      "DEVIDE_FAKE_JOURNAL_LOG" => Path.join(root, "journal.log"),
      "DEVIDE_FAKE_UFW_LOG" => ufw_log,
      "DEV_IDE_LAN_HOST" => "r630.local",
      "DATABASE_PATH" => database_path,
      "PATH" => fakebin <> ":" <> System.get_env("PATH", "")
    }

    %{
      curl_log: curl_log,
      env: env,
      env_file: env_file,
      public_env_file: public_env_file,
      database_path: database_path,
      fakebin: fakebin,
      install_release_dir: install_release_dir,
      release_dir: release_dir,
      script: Path.join(bin_dir, "devide"),
      static_dir: static_dir,
      systemctl_log: systemctl_log,
      unit_dir: unit_dir,
      workspace_root: workspace_root
    }
  end

  defp run_cli(fixture, args, opts \\ []) do
    env =
      fixture.env
      |> Map.merge(opts[:env] || %{})
      |> Enum.map(fn {key, value} -> {key, value} end)

    System.cmd(fixture.script, args,
      cd: Keyword.get(opts, :cd, fixture.release_dir),
      env: env,
      stderr_to_stdout: true
    )
  end

  defp write_executable(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp count_lines(content, prefix) do
    content
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, prefix))
  end
end
