defmodule DevIDE.Agents.AgentShimsTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.AgentShims

  setup do
    prev_bin = Application.get_env(:dev_ide, :agent_bin_dir)
    prev_npm = Application.get_env(:dev_ide, :agent_npm_prefix)
    prev_install = Application.get_env(:dev_ide, :install_agent_shims_path)

    tmp = Path.join(System.tmp_dir!(), "agent-shims-#{System.unique_integer([:positive])}")
    bin = Path.join(tmp, "bin")
    npm = Path.join(tmp, "npm-global")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(npm, "bin"))

    Application.put_env(:dev_ide, :agent_bin_dir, bin)
    Application.put_env(:dev_ide, :agent_npm_prefix, npm)

    on_exit(fn ->
      restore(:agent_bin_dir, prev_bin)
      restore(:agent_npm_prefix, prev_npm)
      restore(:install_agent_shims_path, prev_install)
      File.rm_rf(tmp)
    end)

    %{tmp: tmp, bin: bin, npm: npm}
  end

  test "missing/0 lists incomplete runtimes", %{bin: bin} do
    assert Enum.sort(AgentShims.missing()) == Enum.sort(AgentShims.runtimes())
    refute AgentShims.complete?()

    write_shim!(bin, "grok")
    write_shim!(bin, "claude")

    assert Enum.sort(AgentShims.missing()) == ~w(agent codex opencode)
  end

  test "ensure/0 reports present when complete", %{bin: bin} do
    Enum.each(AgentShims.runtimes(), &write_shim!(bin, &1))
    assert AgentShims.complete?()
    assert {:ok, :present} = AgentShims.ensure()
  end

  test "ensure/0 reinstalls via install script when incomplete", %{bin: bin, tmp: tmp} do
    script = Path.join(tmp, "install-agent-shims.sh")

    File.write!(
      script,
      """
      #!/usr/bin/env bash
      set -euo pipefail
      bin=#{inspect(bin)}
      mkdir -p "$bin"
      for name in grok claude codex opencode agent; do
        printf '%s\\n' '#!/usr/bin/env bash' 'exec true' >"$bin/$name"
        chmod +x "$bin/$name"
      done
      """
    )

    File.chmod!(script, 0o755)
    Application.put_env(:dev_ide, :install_agent_shims_path, script)

    assert {:ok, :installed} = AgentShims.ensure()
    assert AgentShims.complete?()
  end

  test "path helpers expose configured dirs", %{bin: bin, npm: npm} do
    assert AgentShims.bin_dir() == bin
    assert AgentShims.npm_prefix() == npm
    assert AgentShims.npm_bin_dir() == Path.join(npm, "bin")
    assert AgentShims.shim_path("claude") == Path.join(bin, "claude")
  end

  defp write_shim!(bin, name) do
    path = Path.join(bin, name)
    File.write!(path, "#!/usr/bin/env bash\nexec true\n")
    File.chmod!(path, 0o755)
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
