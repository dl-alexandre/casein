defmodule Casein.Scripts.CaseinTestTmuxSocketReaperTest do
  @moduledoc """
  Hermetic coverage for scripts/casein-test-tmux-socket-reaper.sh (#717).

  Stands up a private socket dir + a mock `tmux` that only answers for
  protected labels. Asserts:
    - dry-run leaves everything in place
    - --apply unlinks dead casein_test_* socket files
    - protected labels (casein / casein_dev / …) are never removed
    - out-of-scope socket names are never removed
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/casein-test-tmux-socket-reaper.sh", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "casein-test-tmux-sock-reaper-#{System.unique_integer([:positive])}"
      )

    sock_dir = Path.join(root, "tmux-dir")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(sock_dir)
    File.mkdir_p!(bin_dir)

    write_mock_tmux!(bin_dir)

    # Unix domain sockets the reaper will classify.
    for name <- [
          "casein",
          "casein_dev",
          "devide",
          "default",
          "casein_test_111",
          "casein_test_222",
          "casein-measure-foo",
          "someone_else"
        ] do
      bind_unix_socket!(Path.join(sock_dir, name))
    end

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, sock_dir: sock_dir, bin_dir: bin_dir}
  end

  test "dry-run inventories and removes nothing", ctx do
    {out, 0} = run(ctx, [])

    assert out =~ "DRY RUN"
    assert out =~ "DEAD_SOCKET name=casein_test_111"
    assert out =~ "DEAD_SOCKET name=casein_test_222"
    assert out =~ "DEAD_SOCKET name=casein-measure-foo"
    assert out =~ "PROTECTED name=casein"
    assert out =~ "PROTECTED name=casein_dev"
    assert out =~ "OUT_OF_SCOPE name=someone_else"
    assert out =~ "never touch"

    assert File.exists?(Path.join(ctx.sock_dir, "casein_test_111"))
    assert File.exists?(Path.join(ctx.sock_dir, "casein"))
    assert File.exists?(Path.join(ctx.sock_dir, "someone_else"))
  end

  test "--apply unlinks only dead test sockets", ctx do
    {out, 0} = run(ctx, ["--apply"])

    assert out =~ "unlinked"
    refute out =~ "DRY RUN"

    refute File.exists?(Path.join(ctx.sock_dir, "casein_test_111"))
    refute File.exists?(Path.join(ctx.sock_dir, "casein_test_222"))
    refute File.exists?(Path.join(ctx.sock_dir, "casein-measure-foo"))

    # Protected + out-of-scope stay.
    assert File.exists?(Path.join(ctx.sock_dir, "casein"))
    assert File.exists?(Path.join(ctx.sock_dir, "casein_dev"))
    assert File.exists?(Path.join(ctx.sock_dir, "devide"))
    assert File.exists?(Path.join(ctx.sock_dir, "default"))
    assert File.exists?(Path.join(ctx.sock_dir, "someone_else"))
  end

  test "refuses unknown flags", ctx do
    {out, rc} = run(ctx, ["--explode"])
    assert rc == 1
    assert out =~ "unknown argument"
  end

  defp run(ctx, args) do
    env = [
      {"CASEIN_TEST_TMUX_SOCKET_DIR", ctx.sock_dir},
      {"CASEIN_TMUX_BIN", Path.join(ctx.bin_dir, "tmux")},
      # Keep orphan logic inert in the hermetic suite.
      {"CASEIN_TEST_TMUX_REAP_AGE_MIN", "999999"}
    ]

    System.cmd("bash", [@script | args],
      stderr_to_stdout: true,
      env: env ++ scrub_env()
    )
  end

  # Drop ambient CASEIN_* / TMUX so a shared agent pane cannot redden this.
  defp scrub_env do
    System.get_env()
    |> Enum.reject(fn {k, _} ->
      String.starts_with?(k, "CASEIN_") or k in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"]
    end)
  end

  defp write_mock_tmux!(bin_dir) do
    path = Path.join(bin_dir, "tmux")

    File.write!(path, """
    #!/usr/bin/env bash
    # Mock tmux: only protected labels have a "server". Everything else
    # reports no server — matching a leftover dead socket file.
    set -euo pipefail
    label=""
    if [[ "${1:-}" == "-L" ]]; then
      label="${2:-}"
      shift 2
    fi
    cmd="${1:-}"
    case "$cmd" in
      list-sessions)
        case "$label" in
          casein|casein_dev|devide|devide_dev|default)
            echo "keepalive|att=0|created=1|windows=1"
            exit 0
            ;;
          *)
            echo "no server running on mock/${label}" >&2
            exit 1
            ;;
        esac
        ;;
      *)
        echo "mock tmux: unexpected $*" >&2
        exit 64
        ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end

  defp bind_unix_socket!(path) do
    # Python is always on the box; socat is not. Bind + leave the inode.
    {_, 0} =
      System.cmd(
        "python3",
        [
          "-c",
          """
          import os, socket, sys
          p = sys.argv[1]
          if os.path.exists(p):
              os.unlink(p)
          s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
          s.bind(p)
          # Keep FD open long enough for the inode to exist, then exit;
          # the socket file remains as a disconnected leftover — the
          # state this reaper is built to clean.
          s.close()
          """,
          path
        ],
        stderr_to_stdout: true
      )

    assert File.exists?(path)
  end
end
