defmodule Casein.Release.MobileFeedTimingSoakScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../rel/overlays/bin/mobile_feed_timing_soak", __DIR__)
  @fixed_error "CASEIN_MOBILE_FEED_SOAK_FAILED\n"
  @credential_dir "/etc/casein"

  test "release overlay is executable, shell-valid, and contains only the constant eval surface" do
    assert {"", 0} = System.cmd("sh", ["-n", @script], stderr_to_stdout: true)

    stat = File.stat!(@script)
    assert Bitwise.band(stat.mode, 0o111) != 0

    source = File.read!(@script)

    assert source =~ "--eval 'Casein.Mobile.FeedTimingSoakBridge.run()'"
    assert source =~ "exec 3>&2"
    assert source =~ "unset RELEASE_COOKIE"
    assert source =~ "ERL_CRASH_DUMP=/dev/null"
    assert source =~ "ERL_CRASH_DUMP_SECONDS=0"
    assert source =~ "2>/dev/null"
    assert source =~ "carriage_return"
    assert source =~ String.trim(@fixed_error)
    assert source =~ "credential_dir=\"/etc/casein\""
    assert source =~ "[ -O \"${credential_file}\" ]"
    assert source =~ "[ ! -L \"${credential_file}\" ]"
    assert source =~ "[ ! -w \"${credential_dir}\" ]"

    refute source =~ "bin/casein-runtime"
    refute source =~ " systemctl "
    refute source =~ " clear"
    refute source =~ "mktemp"
    refute source =~ "RELEASE_COOKIE=\""
  end

  test "success forwards stdin only, strips an inherited cookie, and prints only child aggregate JSON" do
    {release_root, script} = fake_release(successful_fake_elixir())
    generations = generations(1..20)
    input = Enum.map_join(generations, "", &(&1 <> "\n"))
    inherited_cookie = String.duplicate("c9", 24)

    port =
      Port.open({:spawn_executable, script}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["ios", "cold"],
        cd: release_root,
        env: [{~c"RELEASE_COOKIE", String.to_charlist(inherited_cookie)}]
      ])

    assert_receive {^port, {:data, "CASEIN_MOBILE_FEED_SOAK_READY\n"}}, 5_000
    refute_receive {^port, {:data, _aggregate_before_finish}}, 50
    assert Port.command(port, input)
    assert {output, 0} = collect_port(port)
    assert output == "{\"component\":\"server\",\"expected_generation_count\":20}\n"

    refute output =~ inherited_cookie
    refute Enum.any?(generations, &String.contains?(output, &1))
  end

  test "invalid scope and noisy runtime failures expose the same single fixed stderr code" do
    {release_root, script} = fake_release(noisy_failing_fake_elixir())

    invalid_port =
      Port.open({:spawn_executable, script}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["IOS", "cold"],
        cd: release_root
      ])

    assert {@fixed_error, 74} == collect_port(invalid_port)

    runtime_port =
      Port.open({:spawn_executable, script}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["android", "reconnect"],
        cd: release_root
      ])

    assert {@fixed_error, 74} == collect_port(runtime_port)
  end

  test "successful runtime stdout noise is rejected without leaking it or an aggregate" do
    {release_root, script} = fake_release(noisy_successful_fake_elixir())
    input = Enum.map_join(generations(41..60), "", &(&1 <> "\n"))

    port =
      Port.open({:spawn_executable, script}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["android", "cold"],
        cd: release_root
      ])

    assert_receive {^port, {:data, "CASEIN_MOBILE_FEED_SOAK_READY\n"}}, 5_000
    refute_receive {^port, {:data, _aggregate_before_finish}}, 50
    assert Port.command(port, input)
    assert {@fixed_error, 74} == collect_port(port)
  end

  test "overlay rejects missing, extra, and case-variant arguments before starting the runtime" do
    {release_root, script} = fake_release(successful_fake_elixir())

    for args <- [[], ["ios"], ["ios", "cold", "extra"], ["iOS", "cold"], ["ios", "Cold"]] do
      port =
        Port.open({:spawn_executable, script}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: release_root
        ])

      assert {@fixed_error, 74} == collect_port(port)
    end
  end

  defp fake_release(fake_elixir_source) do
    root =
      System.tmp_dir!()
      |> Path.join("casein-mobile-feed-soak-#{System.unique_integer([:positive])}")

    bin_dir = Path.join(root, "bin")
    version_dir = Path.join(root, "releases/0.1.0")
    credential_dir = Path.join(root, "credential")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(version_dir)
    File.mkdir_p!(credential_dir)

    script = Path.join(bin_dir, "mobile_feed_timing_soak")

    @script
    |> File.read!()
    |> String.replace(@credential_dir, credential_dir)
    |> then(&File.write!(script, &1))

    File.chmod!(script, 0o755)

    credential_file = Path.join(credential_dir, "casein.env")
    File.write!(credential_file, "RELEASE_COOKIE=#{String.duplicate("d4", 24)}\n")
    File.chmod!(credential_file, 0o600)
    File.chmod!(credential_dir, 0o500)

    File.write!(Path.join(root, "releases/start_erl.data"), "erts-15.0 0.1.0\n")
    File.write!(Path.join(version_dir, "start_clean.boot"), "fixture")
    File.write!(Path.join(version_dir, "remote.vm.args"), "fixture")

    fake_elixir = Path.join(version_dir, "elixir")
    File.write!(fake_elixir, fake_elixir_source)
    File.chmod!(fake_elixir, 0o755)

    on_exit(fn ->
      _ = File.chmod(credential_dir, 0o700)
      _ = File.rm_rf(root)
    end)

    {root, script}
  end

  defp successful_fake_elixir do
    """
    #!/bin/sh
    set -eu

    [ "${RELEASE_COOKIE+x}" != "x" ] || exit 91
    [ "$#" -eq 12 ] || exit 92
    [ "$1" = "--boot" ] || exit 93
    [ "$3" = "--boot-var" ] || exit 94
    [ "$4" = "RELEASE_LIB" ] || exit 95
    [ "$6" = "--vm-args" ] || exit 96
    [ "$8" = "--eval" ] || exit 97
    [ "$9" = "Casein.Mobile.FeedTimingSoakBridge.run()" ] || exit 98
    [ "${10}" = "--" ] || exit 99
    case "${11}:${12}" in
      ios:cold | ios:reconnect | ios:origin_switch | android:cold | android:reconnect | android:origin_switch) ;;
      *) exit 100 ;;
    esac

    printf '%s\n' 'CASEIN_MOBILE_FEED_SOAK_READY' >&3
    printf '%s\n' 'SUPPRESSED_RUNTIME_STDERR' >&2
    bytes="$(dd bs=460 count=1 2>/dev/null | wc -c | tr -d ' ')"
    [ "$bytes" = "460" ] || exit 101
    printf '%s\n' '{"component":"server","expected_generation_count":20}'
    """
  end

  defp noisy_failing_fake_elixir do
    """
    #!/bin/sh
    printf '%s\n' 'UNSAFE_RUNTIME_STDOUT'
    printf '%s\n' 'UNSAFE_RUNTIME_STDERR' >&2
    exit 99
    """
  end

  defp noisy_successful_fake_elixir do
    String.replace(
      successful_fake_elixir(),
      ~s(printf '%s\n' '{"component":"server","expected_generation_count":20}'),
      """
      printf '%s\\n' 'UNSAFE_RUNTIME_STDOUT'
      printf '%s\\n' '{"component":"server","expected_generation_count":20}'
      """
    )
  end

  defp collect_port(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> collect_port(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      5_000 -> flunk("release overlay did not exit")
    end
  end

  defp generations(range), do: Enum.map(range, &generation/1)

  defp generation(index) do
    :sha256
    |> :crypto.hash("casein-release-soak-script-#{index}")
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
