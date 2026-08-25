defmodule Scripts.SpawnHostHeadroomTest do
  @moduledoc """
  Hermetic coverage of scripts/lib/spawn-host-headroom.sh (#863).

  Drives the real helper against planted loadavg/meminfo fixtures — never
  depends on the host's live load (fleet boxes sit above nproc often).
  """
  use ExUnit.Case, async: true

  @helper Path.expand("../../scripts/lib/spawn-host-headroom.sh", __DIR__)
  @spawn Path.expand("../../scripts/spawn-agent-worker.sh", __DIR__)

  test "helper has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @helper])
  end

  test "spawn-agent-worker sources the headroom helper" do
    body = File.read!(@spawn)
    assert body =~ "scripts/lib/spawn-host-headroom.sh"
    assert body =~ "spawn_host_headroom_check"
  end

  test "accepts headroom under thresholds" do
    tmp = tmp!()
    write_probe!(tmp, load1: "4.00", nproc: 32, mem_kb: 40_000_000)

    {out, status} = run_check(tmp, [])
    assert status == 0, out
    refute out =~ "spawn refused"
  end

  test "refuses loudly when load1 exceeds nproc × ratio" do
    tmp = tmp!()
    # Field calibration: healthy ~18.6/32; refuse default is 1.0×nproc.
    write_probe!(tmp, load1: "40.00", nproc: 32, mem_kb: 40_000_000)

    {out, status} = run_check(tmp, [])
    assert status == 75, out
    assert out =~ "spawn refused"
    assert out =~ "load1 40.00 exceeds nproc 32"
    assert out =~ "CASEIN_SPAWN_FORCE=1"
  end

  test "refuses loudly when MemAvailable is below the floor" do
    tmp = tmp!()
    write_probe!(tmp, load1: "1.00", nproc: 32, mem_kb: 100_000)

    {out, status} = run_check(tmp, [{"CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB", "2097152"}])
    assert status == 75, out
    assert out =~ "spawn refused"
    assert out =~ "MemAvailable 100000 KiB below minimum 2097152"
  end

  test "CASEIN_SPAWN_FORCE=1 overrides with a loud warning" do
    tmp = tmp!()
    write_probe!(tmp, load1: "99.00", nproc: 8, mem_kb: 1_000)

    {out, status} = run_check(tmp, [{"CASEIN_SPAWN_FORCE", "1"}])
    assert status == 0, out
    assert out =~ "host headroom below threshold"
    assert out =~ "proceeding under CASEIN_SPAWN_FORCE"
    assert out =~ ~r/^proceed:headroom-force$/m
    refute out =~ "headroom exhausted"
    refute out =~ "spawn refused"
    refute out =~ "refused:headroom"
  end

  test "refusal prints a machine-readable refused:headroom token" do
    tmp = tmp!()
    write_probe!(tmp, load1: "40.00", nproc: 32, mem_kb: 40_000_000)

    {out, status} = run_check(tmp, [])
    assert status == 75, out
    assert out =~ "headroom exhausted"
    assert out =~ ~r/^refused:headroom$/m
    refute out =~ "proceed:headroom-force"
  end

  test "max load ratio is configurable" do
    tmp = tmp!()
    # load 20 / 32 = 0.625; default 1.0 would pass, ratio 0.5 refuses.
    write_probe!(tmp, load1: "20.00", nproc: 32, mem_kb: 40_000_000)

    {pass_out, 0} = run_check(tmp, [{"CASEIN_SPAWN_MAX_LOAD_RATIO", "1.0"}])
    refute pass_out =~ "spawn refused"

    {fail_out, 75} = run_check(tmp, [{"CASEIN_SPAWN_MAX_LOAD_RATIO", "0.5"}])
    assert fail_out =~ "spawn refused"
  end

  test "spawn-agent-worker dry-run declines before printing a launch plan" do
    tmp = tmp!()
    write_probe!(tmp, load1: "80.00", nproc: 8, mem_kb: 40_000_000)

    product = Path.join(tmp, "product")
    home = Path.join(tmp, "home")
    fakebin = Path.join(tmp, "bin")
    Enum.each([product, home, fakebin], &File.mkdir_p!/1)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    env_dir = Path.join([home, ".casein", "agent-mcp", "test"])
    File.mkdir_p!(env_dir)

    File.write!(Path.join(env_dir, "env.sh"), """
    export CASEIN_API_TOKEN='t'
    export CASEIN_WORKSPACE_ID='ws'
    export CASEIN_WORKSPACE_NAME='test'
    """)

    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    {out, status} =
      System.cmd("bash", [@spawn, "claude", "headroom", "casein_test_u-x"],
        env: [
          {"CASEIN_SPAWN_DRY_RUN", "1"},
          {"CASEIN_CHECKOUT", product},
          {"HOME", home},
          {"CASEIN_API_TOKEN", "t"},
          {"CASEIN_WORKSPACE_ID", "ws"},
          {"CASEIN_WORKSPACE_NAME", "test"},
          {"CASEIN_AGENT_ENV_FILE", Path.join(env_dir, "env.sh")},
          {"PATH", fakebin <> ":" <> System.get_env("PATH")},
          {"CASEIN_SPAWN_LOADAVG_PATH", Path.join(tmp, "loadavg")},
          {"CASEIN_SPAWN_MEMINFO_PATH", Path.join(tmp, "meminfo")},
          {"CASEIN_SPAWN_NPROC", "8"},
          {"CASEIN_SPAWN_MAX_LOAD_RATIO", "1.0"},
          {"CASEIN_SPAWN_FORCE", "0"}
        ],
        stderr_to_stdout: true
      )

    assert status == 75, out
    assert out =~ "spawn refused"
    assert out =~ ~r/^refused:headroom$/m
    refute out =~ "proceed:headroom-force"
    refute out =~ ~r/^launch=/m
  end

  test "spawn-agent-worker dry-run FORCE proceeds with a distinct token" do
    tmp = tmp!()
    write_probe!(tmp, load1: "80.00", nproc: 8, mem_kb: 40_000_000)

    product = Path.join(tmp, "product")
    home = Path.join(tmp, "home")
    fakebin = Path.join(tmp, "bin")
    Enum.each([product, home, fakebin], &File.mkdir_p!/1)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "master", product], env: git_env())

    {_, 0} =
      System.cmd("git", ["-C", product, "commit", "-q", "--allow-empty", "-m", "root"],
        env: git_env()
      )

    env_dir = Path.join([home, ".casein", "agent-mcp", "test"])
    File.mkdir_p!(env_dir)

    File.write!(Path.join(env_dir, "env.sh"), """
    export CASEIN_API_TOKEN='t'
    export CASEIN_WORKSPACE_ID='ws'
    export CASEIN_WORKSPACE_NAME='test'
    """)

    File.write!(Path.join(fakebin, "tmux"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(fakebin, "tmux"), 0o755)

    {out, status} =
      System.cmd("bash", [@spawn, "claude", "headroom", "casein_test_u-x"],
        env: [
          {"CASEIN_SPAWN_DRY_RUN", "1"},
          {"CASEIN_SPAWN_FORCE", "1"},
          {"CASEIN_CHECKOUT", product},
          {"HOME", home},
          {"CASEIN_API_TOKEN", "t"},
          {"CASEIN_WORKSPACE_ID", "ws"},
          {"CASEIN_WORKSPACE_NAME", "test"},
          {"CASEIN_AGENT_ENV_FILE", Path.join(env_dir, "env.sh")},
          {"PATH", fakebin <> ":" <> System.get_env("PATH")},
          {"CASEIN_SPAWN_LOADAVG_PATH", Path.join(tmp, "loadavg")},
          {"CASEIN_SPAWN_MEMINFO_PATH", Path.join(tmp, "meminfo")},
          {"CASEIN_SPAWN_NPROC", "8"},
          {"CASEIN_SPAWN_MAX_LOAD_RATIO", "1.0"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ ~r/^proceed:headroom-force$/m
    assert out =~ ~r/^launch=/m
    refute out =~ "headroom exhausted"
    refute out =~ "spawn refused"
    refute out =~ "refused:headroom"
  end

  defp run_check(tmp, extra_env) do
    script = """
    set -euo pipefail
    source "#{@helper}"
    spawn_host_headroom_check
    """

    System.cmd("bash", ["-lc", script],
      env:
        [
          {"CASEIN_SPAWN_LOADAVG_PATH", Path.join(tmp, "loadavg")},
          {"CASEIN_SPAWN_MEMINFO_PATH", Path.join(tmp, "meminfo")},
          {"CASEIN_SPAWN_NPROC", File.read!(Path.join(tmp, "nproc")) |> String.trim()},
          {"CASEIN_SPAWN_MAX_LOAD_RATIO", "1.0"},
          {"CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB", "2097152"},
          {"CASEIN_SPAWN_FORCE", "0"}
        ] ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp write_probe!(tmp, load1: load1, nproc: nproc, mem_kb: mem_kb) do
    File.write!(Path.join(tmp, "loadavg"), "#{load1} 1.00 1.00 1/100 1\n")
    File.write!(Path.join(tmp, "nproc"), "#{nproc}\n")

    File.write!(Path.join(tmp, "meminfo"), """
    MemTotal:       999999999 kB
    MemFree:        #{mem_kb} kB
    MemAvailable:   #{mem_kb} kB
    """)
  end

  defp tmp! do
    tmp = Path.join(System.tmp_dir!(), "spawn-headroom-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@t"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@t"}
    ]
  end
end
