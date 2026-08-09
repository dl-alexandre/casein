defmodule Casein.Scripts.BootstrapRemoteTmuxTest do
  @moduledoc """
  Hermetic coverage for scripts/bootstrap-remote-tmux.sh (#556 slice 2).

  Uses a private CASEIN_REMOTE_TMUX_HOME + mock `tmux` so nothing touches the
  live host labeled server. Asserts:
    - conf is written under ~/.casein/tmux/
    - labeled server is started only when down (exact -L label)
    - --check reports without mutating
    - default / protected labels only; bad labels rejected
    - never invokes bare `tmux` (always -L)
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/bootstrap-remote-tmux.sh", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "casein-bootstrap-remote-tmux-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(home)
    File.mkdir_p!(bin_dir)

    state_file = Path.join(root, "tmux-state")
    File.write!(state_file, "down\n")
    write_mock_tmux!(bin_dir, state_file)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, home: home, bin_dir: bin_dir, state_file: state_file}
  end

  test "bootstrap writes conf and starts labeled server when down", ctx do
    {out, 0} = run(ctx, ["--label", "casein"])

    conf = Path.join(ctx.home, ".casein/tmux/casein.conf")
    assert File.regular?(conf)
    assert File.read!(conf) =~ "exit-empty off"
    assert out =~ "wrote conf"
    assert out =~ "starting labeled server"
    assert out =~ "labeled server is live"
    assert out =~ "native: tmux -L casein list-sessions"
    assert out =~ "default server: never touched"

    # Mock records the start invocation with -L and -f.
    log = File.read!(Path.join(ctx.root, "tmux-log"))
    assert log =~ ~r/-L casein/
    assert log =~ ~r/-f .*casein\.conf/
    assert log =~ "new-session"
    refute log =~ ~r/(^|\n)tmux (?!-)/
  end

  test "idempotent when server already live — does not re-create", ctx do
    File.write!(ctx.state_file, "live\n")
    # Seed conf so rewrite is still ok.
    conf_dir = Path.join(ctx.home, ".casein/tmux")
    File.mkdir_p!(conf_dir)

    {out, 0} = run(ctx, ["--label", "casein"])

    assert out =~ "already live"
    refute out =~ "starting labeled server"

    log = File.read!(Path.join(ctx.root, "tmux-log"))
    refute log =~ "new-session"
  end

  test "--check exits 1 when conf or server missing", ctx do
    {out, code} = run(ctx, ["--check", "--label", "casein"])
    assert code == 1
    assert out =~ "conf:"
    assert out =~ "missing"
  end

  test "--check exits 0 when conf present and server live", ctx do
    conf_dir = Path.join(ctx.home, ".casein/tmux")
    File.mkdir_p!(conf_dir)
    File.write!(Path.join(conf_dir, "casein.conf"), "# ok\n")
    File.write!(ctx.state_file, "live\n")

    {out, 0} = run(ctx, ["--check", "--label", "casein"])
    assert out =~ "server: live"
  end

  test "rejects non-operator labels", ctx do
    {out, code} = run(ctx, ["--label", "casein_test_12345"])
    assert code == 2
    assert out =~ "label must be"
  end

  test "accepts casein_dev label", ctx do
    {out, 0} = run(ctx, ["--label", "casein_dev"])
    assert out =~ "label=casein_dev" or out =~ "-L casein_dev"
    conf = Path.join(ctx.home, ".casein/tmux/casein.conf")
    assert File.regular?(conf)
  end

  defp run(ctx, args) do
    env = [
      {"PATH", "#{ctx.bin_dir}:#{System.get_env("PATH")}"},
      {"HOME", ctx.home},
      {"CASEIN_REMOTE_TMUX_HOME", ctx.home},
      {"CASEIN_TMUX_BIN", Path.join(ctx.bin_dir, "tmux")},
      {"CASEIN_BOOTSTRAP_TEST_STATE", ctx.state_file},
      {"CASEIN_BOOTSTRAP_TEST_LOG", Path.join(ctx.root, "tmux-log")}
    ]

    System.cmd("bash", [@script | args],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp write_mock_tmux!(bin_dir, _state_file) do
    path = Path.join(bin_dir, "tmux")
    # Mock understands -L and the subcommands bootstrap uses. Never answers
    # bare invocations without -L (would mean the script regressed).
    File.write!(path, """
    #!/usr/bin/env bash
    set -euo pipefail
    log="${CASEIN_BOOTSTRAP_TEST_LOG:-/dev/null}"
    state="${CASEIN_BOOTSTRAP_TEST_STATE:?}"
    printf '%s\\n' "$*" >>"$log"

    label=""
    conf=""
    args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -L) label="${2:-}"; shift 2 ;;
        -f) conf="${2:-}"; shift 2 ;;
        -V) echo "tmux 3.7"; exit 0 ;;
        *) args+=("$1"); shift ;;
      esac
    done

    if [[ -z "${label}" ]]; then
      echo "mock-tmux: bare invocation forbidden (missing -L)" >&2
      exit 99
    fi

    sub="${args[0]:-}"
    case "${sub}" in
      has-session)
        if [[ "$(cat "$state")" == "live" ]]; then exit 0; else exit 1; fi
        ;;
      list-sessions)
        if [[ "$(cat "$state")" == "live" ]]; then
          echo "__casein_keepalive: 1 windows (created ...)"
          exit 0
        else
          echo "error connecting to /tmp/tmux/$(id -u)/${label} (No such file or directory)" >&2
          echo "no server running on /tmp/tmux/$(id -u)/${label}" >&2
          exit 1
        fi
        ;;
      new-session)
        # Require -f conf path for start path.
        if [[ -z "${conf}" ]]; then
          echo "mock-tmux: new-session missing -f" >&2
          exit 2
        fi
        echo "live" >"$state"
        exit 0
        ;;
      set-option|source-file)
        exit 0
        ;;
      *)
        echo "mock-tmux: unhandled: ${sub}" >&2
        exit 3
        ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end
end
