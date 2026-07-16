defmodule DevIDE.Agents.GrokCapabilityBundleTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias DevIDE.Agents.GrokCapabilityBundle

  @python_builder Path.expand("../../../scripts/lib/grok-capability-bundle.py", __DIR__)

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "grok-capability-bundle-#{System.unique_integer([:positive, :monotonic])}"
      )

    bundle_root = Path.join(tmp, "bundles")
    leader_root = Path.join(tmp, "leaders")
    inputs = Path.join(tmp, "inputs")
    skills = Path.join(inputs, "skills")
    File.mkdir_p!(Path.join(skills, "verify"))

    mcp = Path.join(inputs, ".mcp.json")
    hook_config = Path.join(inputs, "hooks.json")
    hook_script = Path.join(inputs, "devide-agent-state.sh")

    File.write!(
      mcp,
      ~s({"mcpServers":{"devide":{"headers":{"Authorization":"Bearer ${DEV_IDE_API_TOKEN}"}}}}\n)
    )

    File.write!(hook_config, ~s({"hooks":{"SessionStart":[]}}\n))
    File.write!(hook_script, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(hook_script, 0o755)
    File.write!(Path.join([skills, "verify", "SKILL.md"]), "# Verify\n")

    previous_bundle_root = Application.get_env(:dev_ide, :grok_capability_bundle_root)
    previous_leader_root = Application.get_env(:dev_ide, :grok_leader_root)
    Application.put_env(:dev_ide, :grok_capability_bundle_root, bundle_root)
    Application.put_env(:dev_ide, :grok_leader_root, leader_root)

    on_exit(fn ->
      restore_env(:grok_capability_bundle_root, previous_bundle_root)
      restore_env(:grok_leader_root, previous_leader_root)
      make_writable(tmp)
      File.rm_rf!(tmp)
    end)

    %{
      tmp: tmp,
      bundle_root: bundle_root,
      mcp: mcp,
      hook_config: hook_config,
      hook_script: hook_script,
      skills: skills
    }
  end

  test "compiles one immutable bundle and reuses it by content digest", context do
    opts = compile_opts(context)

    assert {:ok, first} = GrokCapabilityBundle.compile(opts)
    assert {:ok, second} = GrokCapabilityBundle.compile(opts)
    assert first == second
    assert Path.basename(first.dir) == "sha256-#{first.digest}"
    assert first.digest =~ ~r/^[0-9a-f]{64}$/
    assert GrokCapabilityBundle.allowed_path?(first.dir)
    assert :ok = GrokCapabilityBundle.verify(first.dir, first.digest)

    assert File.read!(Path.join(first.dir, ".mcp.json")) =~ "${DEV_IDE_API_TOKEN}"
    assert File.regular?(Path.join([first.dir, "hooks", "devide-agent-state.sh"]))
    assert File.regular?(Path.join([first.dir, "skills", "verify", "SKILL.md"]))

    for path <- [first.dir | descendants(first.dir)] do
      assert band(File.stat!(path).mode, 0o222) == 0
      refute match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
    end
  end

  test "shell and Elixir compilers produce the same content digest", context do
    assert {:ok, bundle} = GrokCapabilityBundle.compile(compile_opts(context))
    python_root = Path.join(context.tmp, "python-bundles")

    {output, 0} =
      System.cmd("python3", [
        @python_builder,
        "build",
        "--bundle-root",
        python_root,
        "--mcp-config",
        context.mcp,
        "--hook-config",
        context.hook_config,
        "--hook-script",
        context.hook_script,
        "--skills-root",
        context.skills,
        "--skill",
        "verify"
      ])

    [python_dir, python_digest] = String.split(String.trim(output), "\n")
    assert python_digest == bundle.digest
    assert Path.basename(python_dir) == Path.basename(bundle.dir)

    assert {^python_digest, 0} =
             System.cmd("python3", [
               @python_builder,
               "verify",
               python_dir,
               "--digest",
               python_digest
             ])
             |> then(fn {text, status} -> {String.trim(text), status} end)
  end

  test "rejects skill trees containing symlinks", context do
    File.ln_s!(context.mcp, Path.join([context.skills, "verify", "escaped.json"]))

    assert {:error, _reason} = GrokCapabilityBundle.compile(compile_opts(context))
  end

  test "derives a stable private leader socket from workspace and checkout", context do
    assert {:ok, first} = GrokCapabilityBundle.leader_socket("workspace-1", context.tmp)
    assert {:ok, second} = GrokCapabilityBundle.leader_socket("workspace-1", context.tmp)
    assert first == second
    assert Path.dirname(first) == Path.join(context.tmp, "leaders")
    assert Path.basename(first) =~ ~r/^[0-9a-f]{24}\.sock$/
    assert band(File.stat!(Path.dirname(first)).mode, 0o077) == 0
  end

  defp compile_opts(context) do
    [
      bundle_root: context.bundle_root,
      mcp_config: context.mcp,
      hook_config: context.hook_config,
      hook_script: context.hook_script,
      skills_root: context.skills,
      skills: ["verify"]
    ]
  end

  defp descendants(root) do
    root
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      path = Path.join(root, name)
      if File.dir?(path), do: [path | descendants(path)], else: [path]
    end)
  end

  defp make_writable(path) do
    if File.exists?(path) do
      _ = File.chmod(path, 0o700)
      Enum.each(descendants(path), &File.chmod(&1, if(File.dir?(&1), do: 0o700, else: 0o600)))
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
