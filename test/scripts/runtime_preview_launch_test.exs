defmodule Scripts.RuntimePreviewLaunchTest do
  @moduledoc """
  Regression coverage for the env scrub in runtime-preview-launch.sh.

  The launcher inherits the running cockpit's environment. On 2026-07-29 a
  preview started from an agent worktree inherited `CASEIN_HTTP_SOCKET`, which
  `config/runtime.exs` honours in `:dev` too — so `mix phx.server` bound the
  *production* instance socket instead of `$PORT`, served prod traffic from a
  dev build (workspace deep links 404ing, terminals falling back to the $HOME
  scratch PTY), and made the next release boot fail with `:eaddrinuse`.

  Drives the real script with a fake preview command that records what it
  inherited — no Phoenix, no release, no unix socket squatting.
  """
  use ExUnit.Case, async: true

  @launcher Path.expand("../../priv/scripts/runtime-preview-launch.sh", __DIR__)

  # Every var the launcher must strip before handing off to a dev server.
  @dangerous %{
    "CASEIN_HTTP_SOCKET" => "/run/casein/instances/deadbeefdeadbeef.sock",
    "CASEIN_INSTANCE_UUID" => "deadbeefdeadbeef",
    "CASEIN_GIT_REVISION" => "0000000000000000000000000000000000000000",
    "RELEASE_ROOT" => "/opt/casein/release",
    "RELEASE_NODE" => "casein_deadbeefdeadbeef@testhost",
    "RELEASE_COOKIE" => "inherited-cookie",
    "RELEASE_SYS_CONFIG" => "/opt/casein/release/releases/0.1.0/sys",
    "RELEASE_VM_ARGS" => "/opt/casein/release/releases/0.1.0/vm.args"
  }

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "runtime-preview-launch-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "strips inherited release/instance env before starting the preview", %{tmp: tmp} do
    inherited = run_launcher(tmp)

    for {var, _value} <- @dangerous do
      assert inherited[var] == "<unset>",
             "#{var} leaked into the preview as #{inspect(inherited[var])} — the preview " <>
               "would boot against the deployed release's socket/config instead of its own"
    end
  end

  test "still passes the assigned PORT through to the preview command", %{tmp: tmp} do
    port = free_port()

    inherited = run_launcher(tmp, port)

    assert inherited["PORT"] == Integer.to_string(port)
  end

  # Runs the launcher with a fake preview command that dumps the vars it sees
  # and then holds the port open (the launcher waits for the port before it
  # writes its registry record). Returns the recorded var => value map, with
  # "<unset>" for anything absent.
  defp run_launcher(tmp, port \\ nil) do
    port = port || free_port()
    facts = Path.join(tmp, "inherited.env")
    vars = Map.keys(@dangerous) ++ ["PORT"]

    # Single line on purpose: build_command() reads the command through
    # `mapfile -t`, which keeps only the first line of a multi-line value.
    dump =
      Enum.map_join(vars, "; ", fn var ->
        ~s(printf '#{var}=%s\\n' "${#{var}:-<unset>}" >> "$PREVIEW_FACTS")
      end)

    command = dump <> ~s(; exec python3 -m http.server "$PORT" --bind 127.0.0.1)

    env =
      [
        {"PREVIEW_FACTS", facts},
        {"CASEIN_RUNTIME_ID", "launcher-test"},
        {"CASEIN_RUNTIME_PREVIEW_COMMAND", command},
        # Pin the launcher's state dir and proxy socket into tmp. `mix test`
        # usually runs inside a Casein terminal, which exports both of these —
        # inheriting them would scatter registry/log/socket files into the
        # developer's real workspace preview home.
        {"CASEIN_PREVIEW_HOME", Path.join(tmp, ".casein-preview")},
        {"CASEIN_RUNTIME_PREVIEW_SOCKET", Path.join(tmp, "preview.sock")}
      ] ++ Enum.map(@dangerous, fn {var, value} -> {var, value} end)

    # setsid + recorded pgid so the launcher, its dev server, and any socat
    # proxy all die with the test instead of leaking a listener.
    launcher_out = Path.join(tmp, "launcher.out")

    {out, 0} =
      System.cmd(
        "bash",
        ["-c", "setsid bash #{@launcher} --port #{port} > #{launcher_out} 2>&1 & echo $!"],
        cd: tmp,
        env: env
      )

    pgid = String.trim(out)
    on_exit(fn -> System.cmd("bash", ["-c", "kill -- -#{pgid} 2>/dev/null || true"]) end)

    await_facts(facts, launcher_out)

    facts
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [var, value] = String.split(line, "=", parts: 2)
      {var, value}
    end)
  end

  defp await_facts(path, launcher_out) do
    try do
      Casein.Test.Eventually.await(
        fn ->
          (File.exists?(path) and File.read!(path) =~ "PORT=") && :ok
        end,
        timeout_ms: 10_000,
        interval_ms: 20,
        message: "preview command never recorded its environment at #{path}"
      )
    rescue
      ExUnit.AssertionError ->
        flunk("""
        preview command never recorded its environment at #{path}

        launcher output:
        #{File.read(launcher_out) |> elem(1)}
        """)
    end
  end

  # Bind :0, read the assigned port, release it. Racy in principle, but the
  # launcher claims it within a second and a collision only reruns the test.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
