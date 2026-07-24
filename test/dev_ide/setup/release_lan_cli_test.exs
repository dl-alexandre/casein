defmodule Casein.Setup.ReleaseLanCliTest do
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

  test "release metadata commands run with release root and CLI runtime marker" do
    fixture = release_fixture()

    assert {_, 0} = run_cli(fixture, ["version", "--json"], cd: "/")

    log = File.read!(fixture.app_bin_log)
    assert log =~ "DEV_IDE_RELEASE_CLI=1"
    assert log =~ "DEVIDE_RELEASE_ROOT=#{fixture.release_dir}"
    assert log =~ "args:eval Casein.Release.CLI.main_base64("
  end

  test "release LAN CLI installs a managed backend and HTTP edge" do
    text = File.read!(@script)

    assert text =~ "BACKEND_SERVICE=\"devide-lan.service\""
    assert text =~ "EDGE_SOCKET=\"devide-lan-http-edge.socket\""
    assert text =~ "append_env_if_missing DEV_IDE_LAN_INSECURE_HTTP true"
    assert text =~ "append_env_if_missing DEV_IDE_HOME_WORKSPACE_PATH"
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
    assert env =~ "DEV_IDE_LAN_IP='192.168.1.240'"
    assert env =~ "DEV_IDE_HOME_WORKSPACE_PATH='#{fixture.home_workspace_path}'"

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

    chown_log = File.read!(fixture.chown_log)
    refute chown_log =~ "-R"
    assert chown_log =~ Path.dirname(fixture.database_path)
    assert chown_log =~ fixture.workspace_root
    refute chown_log =~ fixture.home_workspace_path

    public_env = File.read!(fixture.public_env_file)
    assert public_env =~ "PORT='4010'"
    assert public_env =~ "DEV_IDE_LAN_HOST='devide.home.arpa'"
    assert public_env =~ "DEV_IDE_LAN_IP='192.168.1.240'"
    assert public_env =~ "DEV_IDE_LAN_INSECURE_HTTP_PORT='8080'"
    assert public_env =~ "DEV_IDE_HOME_WORKSPACE_PATH='#{fixture.home_workspace_path}'"
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

  test "install rejects unsafe database paths before ownership changes" do
    fixture = release_fixture()

    assert {out, 1} =
             run_cli(fixture, ["lan", "install"], env: %{"DATABASE_PATH" => "/etc/passwd"})

    assert out =~ "DATABASE_PATH directory points at protected system path: /etc"
    chown_log = if File.exists?(fixture.chown_log), do: File.read!(fixture.chown_log), else: ""
    refute chown_log =~ ~r/(^|\s)\/etc(\s|$)/
  end

  test "install rejects workspace traversal names before ownership changes" do
    fixture = release_fixture()

    assert {out, 1} =
             run_cli(fixture, ["lan", "install"],
               env: %{"DEV_IDE_DEFAULT_WORKSPACE" => "../outside"}
             )

    assert out =~ "DEV_IDE_DEFAULT_WORKSPACE is not a safe workspace name"
    chown_log = if File.exists?(fixture.chown_log), do: File.read!(fixture.chown_log), else: ""
    refute chown_log =~ fixture.workspace_root
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

    env = File.read!(fixture.env_file)
    assert env =~ "DEV_IDE_DEFAULT_WORKSPACE='home'"
    assert env =~ "DEV_IDE_HOME_WORKSPACE_PATH='#{fixture.home_workspace_path}'"
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

  test "status does not treat redirected CSS assets as ready" do
    fixture = release_fixture()

    assert {out, 1} =
             run_cli(fixture, ["lan", "status"], env: %{"DEVIDE_FAKE_ASSET_CODE" => "302"})

    assert out =~ "NOT READY http://r630.local/"
    assert out =~ "WARN      http://r630.local/assets/css/app.css returned HTTP 302"
    refute out =~ "READY     http://r630.local/"
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

  test "update install migrates the durable release to symlinks and activates the artifact" do
    fixture = release_fixture()

    assert {_, 0} = run_cli(fixture, ["lan", "install"])
    assert File.dir?(fixture.install_release_dir)

    assert {out, 0} = run_cli(fixture, ["update", "install"])

    assert out =~ "Installing DevIDE LAN release 67f393a"
    assert out =~ "Installed DevIDE LAN release 67f393a."
    assert out =~ "READY     http://r630.local/"

    assert File.read_link(fixture.install_release_dir) == {:ok, fixture.current_link}
    assert File.read_link(fixture.current_link) == {:ok, "releases/#{fixture.update_revision}"}
    assert File.read_link(fixture.previous_link) == {:ok, "releases/#{fixture.current_revision}"}

    assert File.exists?(Path.join(fixture.releases_dir, "#{fixture.current_revision}/bin/devide"))
    assert File.exists?(Path.join(fixture.releases_dir, "#{fixture.update_revision}/bin/devide"))
    assert File.exists?(Path.join(fixture.downloads_dir, Path.basename(fixture.update_tarball)))

    systemctl_log = File.read!(fixture.systemctl_log)
    assert systemctl_log =~ "restart devide-lan.service"

    curl_log = File.read!(fixture.curl_log)
    assert curl_log =~ fixture.artifact_url
    assert curl_log =~ "http://r630.local/assets/css/app.css"
  end

  test "update rollback swaps current and previous releases back" do
    fixture = release_fixture()

    assert {_, 0} = run_cli(fixture, ["lan", "install"])
    assert {_, 0} = run_cli(fixture, ["update", "install"])

    assert {out, 0} = run_cli(fixture, ["update", "rollback"])

    assert out =~ "Rolled back DevIDE LAN release."
    assert File.read_link(fixture.current_link) == {:ok, "releases/#{fixture.current_revision}"}
    assert File.read_link(fixture.previous_link) == {:ok, "releases/#{fixture.update_revision}"}
    assert File.read_link(fixture.install_release_dir) == {:ok, fixture.current_link}
  end

  test "update install rolls back symlinks when post-install probes fail" do
    fixture = release_fixture()

    assert {_, 0} = run_cli(fixture, ["lan", "install"])

    assert {out, 1} =
             run_cli(fixture, ["update", "install"],
               env: %{"DEVIDE_FAKE_ASSET_CODE" => "302", "DEVIDE_LAN_READY_ATTEMPTS" => "1"}
             )

    assert out =~ "updated release did not become ready; rolling back"
    assert File.read_link(fixture.current_link) == {:ok, "releases/#{fixture.current_revision}"}
    assert File.read_link(fixture.previous_link) == {:error, :enoent}
    assert File.read_link(fixture.install_release_dir) == {:ok, fixture.current_link}
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
    home_workspace_path = Path.join(root, "home")
    install_release_dir = Path.join(root, "opt/devide/lan-release")
    update_root = Path.join(root, "opt/devide/lan")
    releases_dir = Path.join(update_root, "releases")
    downloads_dir = Path.join(update_root, "downloads")
    current_link = Path.join(update_root, "current")
    previous_link = Path.join(update_root, "previous")
    systemctl_log = Path.join(root, "systemctl.log")
    curl_log = Path.join(root, "curl.log")
    chown_log = Path.join(root, "chown.log")
    ufw_log = Path.join(root, "ufw.log")
    app_bin_log = Path.join(root, "app-bin.log")
    plan_file = Path.join(root, "install-plan.env")
    artifact_url = "https://example.com/devide-lan-linux-x86_64-67f393a.tar.gz"
    current_revision = "504670cdeadbeef"
    update_revision = "67f393adeadbeef"

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(fakebin)
    File.mkdir_p!(home_workspace_path)

    File.cp!(@script, Path.join(bin_dir, "devide"))
    File.chmod!(Path.join(bin_dir, "devide"), 0o755)

    write_executable(Path.join(bin_dir, "dev_ide"), """
    #!/bin/sh
    {
      printf 'DEV_IDE_RELEASE_CLI=%s\\n' "${DEV_IDE_RELEASE_CLI:-}"
      printf 'DEVIDE_RELEASE_ROOT=%s\\n' "${DEVIDE_RELEASE_ROOT:-}"
      printf 'args:%s\\n' "$*"
    } >> "$DEVIDE_FAKE_APP_BIN_LOG"
    case "$0:$*" in
      *"/releases/${DEVIDE_FAKE_CURRENT_REVISION}/bin/dev_ide:"*InstallPlan.print_metadata_shell_base64*)
        echo "old release does not contain InstallPlan" >&2
        exit 1
        ;;
    esac
    case "$*" in
      *InstallPlan.print_shell_base64*)
        cat "$DEVIDE_FAKE_INSTALL_PLAN"
        exit 0
        ;;
      *InstallPlan.print_metadata_shell_base64*)
        if [ -f "$DEVIDE_RELEASE_ROOT/.fake-relmeta-shell" ]; then
          cat "$DEVIDE_RELEASE_ROOT/.fake-relmeta-shell"
        else
          cat "$DEVIDE_FAKE_CURRENT_METADATA"
        fi
        exit 0
        ;;
    esac
    exit 0
    """)

    write_executable(Path.join(bin_dir, "migrate"), "#!/bin/sh\nexit 0\n")
    static_dir = Path.join(release_dir, "lib/dev_ide-0.1.0/priv/static")
    File.mkdir_p!(Path.join(static_dir, "assets/css"))
    File.mkdir_p!(Path.join(static_dir, "assets/js"))
    File.write!(Path.join(static_dir, "cache_manifest.json"), "{}\n")
    File.write!(Path.join(static_dir, "assets/css/app.css"), "body{}\n")
    File.write!(Path.join(static_dir, "assets/js/app.js"), "console.log('ok')\n")

    current_metadata =
      release_metadata(
        revision: current_revision,
        update_manifest_url: "https://example.com/devide-canary.json"
      )

    update_metadata =
      release_metadata(
        revision: update_revision,
        update_manifest_url: "https://example.com/devide-canary.json"
      )

    write_release_metadata_files(release_dir, current_metadata)

    update_release_dir = Path.join(root, "update-release")

    write_fake_release_tree(
      update_release_dir,
      Path.join(bin_dir, "devide"),
      File.read!(Path.join(bin_dir, "dev_ide")),
      update_metadata
    )

    update_tarball = Path.join(root, "devide-lan-linux-x86_64-67f393a.tar.gz")
    assert {_, 0} = System.cmd("tar", ["-czf", update_tarball, "-C", update_release_dir, "."])
    update_sha = sha256_hex(update_tarball)

    File.write!(
      plan_file,
      install_plan_shell(
        current_metadata,
        update_metadata,
        artifact_url: artifact_url,
        sha256: update_sha
      )
    )

    write_executable(Path.join(fakebin, "systemd-socket-proxyd"), "#!/bin/sh\nexit 0\n")

    write_executable(Path.join(fakebin, "chown"), """
    #!/bin/sh
    echo "$*" >> "$DEVIDE_FAKE_CHOWN_LOG"
    exit 0
    """)

    write_executable(Path.join(fakebin, "getent"), """
    #!/bin/sh
    if [ "$1" = "passwd" ]; then
      echo "$2:x:1000:1000::${DEVIDE_FAKE_HOME}:/bin/bash"
      exit 0
    fi
    exit 2
    """)

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
    output=""
    last=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-o" ]; then
        shift
        output="$1"
      fi
      last="$1"
      shift
    done
    echo "$last" >> "$DEVIDE_FAKE_CURL_LOG"
    if [ "$output" != "" ] && [ "$last" = "$DEVIDE_FAKE_ARTIFACT_URL" ]; then
      cp "$DEVIDE_FAKE_UPDATE_TARBALL" "$output"
      exit 0
    fi
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
      "DEVIDE_LAN_UPDATE_ROOT" => update_root,
      "DEVIDE_LAN_UNIT_DIR" => unit_dir,
      "DEVIDE_LAN_USER" => user,
      "DEVIDE_LAN_WORKSPACES_ROOT" => workspace_root,
      "DEVIDE_FAKE_SYSTEMCTL_LOG" => systemctl_log,
      "DEVIDE_FAKE_CURL_LOG" => curl_log,
      "DEVIDE_FAKE_CHOWN_LOG" => chown_log,
      "DEVIDE_FAKE_APP_BIN_LOG" => app_bin_log,
      "DEVIDE_FAKE_INSTALL_PLAN" => plan_file,
      "DEVIDE_FAKE_CURRENT_REVISION" => current_revision,
      "DEVIDE_FAKE_CURRENT_METADATA" => Path.join(release_dir, ".fake-relmeta-shell"),
      "DEVIDE_FAKE_ARTIFACT_URL" => artifact_url,
      "DEVIDE_FAKE_UPDATE_TARBALL" => update_tarball,
      "DEVIDE_FAKE_HOME" => home_workspace_path,
      "DEVIDE_FAKE_JOURNAL_LOG" => Path.join(root, "journal.log"),
      "DEVIDE_FAKE_UFW_LOG" => ufw_log,
      "DEV_IDE_LAN_HOST" => "r630.local",
      "DATABASE_PATH" => database_path,
      "PATH" => fakebin <> ":" <> System.get_env("PATH", "")
    }

    %{
      app_bin_log: app_bin_log,
      artifact_url: artifact_url,
      curl_log: curl_log,
      chown_log: chown_log,
      current_link: current_link,
      current_revision: current_revision,
      downloads_dir: downloads_dir,
      env: env,
      env_file: env_file,
      home_workspace_path: home_workspace_path,
      public_env_file: public_env_file,
      database_path: database_path,
      fakebin: fakebin,
      install_release_dir: install_release_dir,
      previous_link: previous_link,
      release_dir: release_dir,
      releases_dir: releases_dir,
      script: Path.join(bin_dir, "devide"),
      static_dir: static_dir,
      systemctl_log: systemctl_log,
      unit_dir: unit_dir,
      update_revision: update_revision,
      update_root: update_root,
      update_tarball: update_tarball,
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

  defp write_fake_release_tree(release_dir, devide_script, app_script, metadata) do
    bin_dir = Path.join(release_dir, "bin")
    static_dir = Path.join(release_dir, "lib/dev_ide-0.1.0/priv/static")

    File.mkdir_p!(bin_dir)
    File.cp!(devide_script, Path.join(bin_dir, "devide"))
    File.chmod!(Path.join(bin_dir, "devide"), 0o755)
    write_executable(Path.join(bin_dir, "dev_ide"), app_script)
    write_executable(Path.join(bin_dir, "migrate"), "#!/bin/sh\nexit 0\n")

    File.mkdir_p!(Path.join(static_dir, "assets/css"))
    File.mkdir_p!(Path.join(static_dir, "assets/js"))
    File.write!(Path.join(static_dir, "cache_manifest.json"), "{}\n")
    File.write!(Path.join(static_dir, "assets/css/app.css"), "body{}\n")
    File.write!(Path.join(static_dir, "assets/js/app.js"), "console.log('ok')\n")
    write_release_metadata_files(release_dir, metadata)
  end

  defp write_release_metadata_files(release_dir, metadata) do
    File.write!(
      Path.join(release_dir, ".fake-relmeta-shell"),
      metadata_shell("METADATA", metadata) |> Enum.join("\n") |> Kernel.<>("\n")
    )

    File.mkdir_p!(Path.join(release_dir, "releases"))

    File.write!(
      Path.join(release_dir, "releases/dev_ide.relmeta.json"),
      Jason.encode!(metadata_json(metadata), pretty: true) <> "\n"
    )
  end

  defp release_metadata(opts) do
    %{
      app: "devide",
      version: "0.1.0",
      revision: Keyword.fetch!(opts, :revision),
      profile: "lan",
      repo_adapter: "sqlite",
      target: "linux-x86_64",
      channel: "canary",
      update_manifest_url: Keyword.fetch!(opts, :update_manifest_url),
      built_at: "2026-07-02T12:00:00Z"
    }
  end

  defp metadata_json(metadata) do
    %{
      "metadata_version" => 1,
      "app" => metadata.app,
      "version" => metadata.version,
      "revision" => metadata.revision,
      "profile" => metadata.profile,
      "repo_adapter" => metadata.repo_adapter,
      "target" => metadata.target,
      "channel" => metadata.channel,
      "update_manifest_url" => metadata.update_manifest_url,
      "built_at" => metadata.built_at
    }
  end

  defp install_plan_shell(current, artifact, opts) do
    artifact_url = Keyword.fetch!(opts, :artifact_url)
    sha256 = Keyword.fetch!(opts, :sha256)

    [
      "PLAN_STATUS=update_available",
      "MANIFEST_CHANNEL_B64=#{Base.encode64(current.channel)}",
      "MANIFEST_URL_B64=#{Base.encode64(current.update_manifest_url)}",
      metadata_shell("CURRENT", current),
      metadata_shell("ARTIFACT", artifact),
      "ARTIFACT_URL_B64=#{Base.encode64(artifact_url)}",
      "ARTIFACT_SHA256_B64=#{Base.encode64(sha256)}",
      "ARTIFACT_SIZE=#{File.stat!(Path.expand(opts[:tarball] || __ENV__.file)).size}"
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp metadata_shell(prefix, metadata) do
    [
      "#{prefix}_APP_B64=#{Base.encode64(metadata.app)}",
      "#{prefix}_VERSION_B64=#{Base.encode64(metadata.version)}",
      "#{prefix}_REVISION_B64=#{Base.encode64(metadata.revision)}",
      "#{prefix}_PROFILE_B64=#{Base.encode64(metadata.profile)}",
      "#{prefix}_REPO_ADAPTER_B64=#{Base.encode64(metadata.repo_adapter)}",
      "#{prefix}_TARGET_B64=#{Base.encode64(metadata.target)}",
      "#{prefix}_CHANNEL_B64=#{Base.encode64(metadata.channel)}"
    ]
  end

  defp sha256_hex(path) do
    path
    |> File.stream!(8192, [:read, :binary])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
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
