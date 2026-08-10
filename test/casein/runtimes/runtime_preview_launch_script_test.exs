defmodule Casein.Runtimes.RuntimePreviewLaunchScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../priv/scripts/runtime-preview-launch.sh", __DIR__)
  @windows_script Path.expand("../../../priv/scripts/runtime-preview-launch.ps1", __DIR__)

  test "has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "fails before starting the app when the assigned port is occupied" do
    root =
      Path.join(
        System.tmp_dir!(),
        "casein-runtime-launch-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    marker = Path.join(root, "app-started")

    env = [
      {"CASEIN_PREVIEW_HOME", Path.join(root, ".casein-preview")},
      {"CASEIN_RUNTIME_ID", "occupied-port"},
      {"CASEIN_RUNTIME_PREVIEW_COMMAND", "touch #{marker}"}
    ]

    assert {_output, 1} =
             System.cmd("bash", [@script, "--port", Integer.to_string(port)],
               cd: root,
               env: env,
               stderr_to_stdout: true
             )

    refute File.exists?(marker)

    registry =
      root
      |> Path.join(".casein-preview/instances/occupied-port.json")
      |> File.read!()
      |> Jason.decode!()

    assert registry["status"] == "failed"
    assert registry["port"] == Integer.to_string(port)
    assert registry["worktree"] == root
  end

  test "windows launcher declares kill-on-close Job Object process-tree cleanup" do
    script = File.read!(@windows_script)

    assert script =~ "Initialize-CaseinPreviewJobObjectSupport"
    assert script =~ "PreviewJobObject"
    assert script =~ "CreateKillOnClose"
    assert script =~ "AssignProcessToJobObject"
    assert script =~ "Stop-PreviewProcessTree"
    assert script =~ "JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE"
    assert script =~ "process_tree = 'job_object_kill_on_close'"
    # Fallback remains when Job Object assignment is unavailable.
    assert script =~ "taskkill.exe /PID"
    assert script =~ "/T"
  end
end
