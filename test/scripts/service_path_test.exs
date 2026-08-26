defmodule Scripts.ServicePathTest do
  @moduledoc """
  Hermetic coverage of scripts/lib/service-path.sh — the canary unit PATH
  that lets Commands.spawn resolve allowlisted verifier tools (`mix`).
  """
  use ExUnit.Case, async: true

  @helper Path.expand("../../scripts/lib/service-path.sh", __DIR__)
  @deploy Path.expand("../../scripts/deploy-devbox-release.sh", __DIR__)

  @systemd_default "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  test "helper has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @helper])
  end

  test "deploy-devbox-release sources the helper and pins PATH on the canary unit" do
    body = File.read!(@deploy)
    assert body =~ "scripts/lib/service-path.sh"
    assert body =~ ~s|SERVICE_PATH="$(casein_service_path "${USER_NAME}")"|
    assert body =~ ~s|--property="Environment=PATH=${SERVICE_PATH}"|
    refute body =~ "/home/devbox/.local/bin"
  end

  test "helper does not hardcode a host home" do
    refute File.read!(@helper) =~ "/home/devbox"
  end

  test "prepends <home>/.local/bin to the systemd default PATH" do
    home = tmp!()
    path = service_path(%{"CASEIN_DEPLOY_HOME" => home})
    assert path == "#{home}/.local/bin:#{@systemd_default}"
  end

  test "CASEIN_SERVICE_PATH overrides the entire PATH" do
    override = "/opt/custom/bin:/usr/bin"
    path = service_path(%{"CASEIN_SERVICE_PATH" => override, "CASEIN_DEPLOY_HOME" => "/ignored"})
    assert path == override
  end

  test "CASEIN_TOOL_BIN_DIR overrides the default tool directory" do
    tool = Path.join(tmp!(), "tools")
    path = service_path(%{"CASEIN_TOOL_BIN_DIR" => tool, "CASEIN_DEPLOY_HOME" => "/ignored"})
    assert path == "#{tool}:#{@systemd_default}"
  end

  test "does not duplicate the tool dir when it is already on the base PATH" do
    home = tmp!()
    tool = "#{home}/.local/bin"
    base = "#{tool}:/usr/bin:/bin"

    path =
      service_path(%{
        "CASEIN_DEPLOY_HOME" => home,
        "CASEIN_SERVICE_BASE_PATH" => base
      })

    assert path == base
  end

  test "falls back to the systemd default when no home or tool dir is available" do
    path =
      service_path(%{
        "HOME" => "",
        "CASEIN_DEPLOY_HOME" => "",
        "CASEIN_TOOL_BIN_DIR" => "",
        "CASEIN_DEPLOY_USER" => "",
        "USER_NAME" => ""
      })

    assert path == @systemd_default
  end

  test "diagnostic reports mix missing on the systemd default PATH" do
    out =
      service_resolve("mix", %{
        "HOME" => "",
        "CASEIN_DEPLOY_HOME" => "",
        "CASEIN_TOOL_BIN_DIR" => "",
        "CASEIN_DEPLOY_USER" => "",
        "USER_NAME" => ""
      })

    assert out =~ "PATH=#{@systemd_default}"
    assert out =~ "mix=missing"
  end

  test "diagnostic resolves a planted mix under the configurable tool dir" do
    tmp = tmp!()
    tool = Path.join(tmp, "bin")
    File.mkdir_p!(tool)
    mix = Path.join(tool, "mix")
    File.write!(mix, "#!/bin/sh\nexit 0\n")
    File.chmod!(mix, 0o755)

    out = service_resolve("mix", %{"CASEIN_TOOL_BIN_DIR" => tool})
    assert out =~ "PATH=#{tool}:#{@systemd_default}"
    assert out =~ "mix=#{mix}"
  end

  defp service_path(extra_env) do
    {out, 0} = run_helper("casein_service_path", extra_env)
    String.trim(out)
  end

  defp service_resolve(bin, extra_env) do
    {out, 0} = run_helper("casein_service_resolve #{shell_quote(bin)}", extra_env)
    out
  end

  defp run_helper(call, extra_env) do
    script = """
    set -euo pipefail
    source #{shell_quote(@helper)}
    #{call}
    """

    System.cmd("bash", ["-c", script],
      env: helper_env(extra_env),
      stderr_to_stdout: true
    )
  end

  defp helper_env(extra_env) do
    base = %{
      "PATH" => System.get_env("PATH", "/usr/bin:/bin"),
      "HOME" => "",
      "CASEIN_DEPLOY_HOME" => "",
      "CASEIN_TOOL_BIN_DIR" => "",
      "CASEIN_SERVICE_PATH" => "",
      "CASEIN_SERVICE_BASE_PATH" => "",
      "CASEIN_DEPLOY_USER" => "",
      "USER_NAME" => ""
    }

    base
    |> Map.merge(extra_env)
    |> Enum.map(fn {k, v} -> {k, v} end)
  end

  defp tmp! do
    tmp = Path.join(System.tmp_dir!(), "service-path-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
