defmodule DevIDE.Agents.AuthProfileTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.AuthProfile

  setup do
    prev_root = Application.get_env(:dev_ide, :agent_auth_profile_root)
    tmp = Path.join(System.tmp_dir!(), "agent-auth-profile-#{System.unique_integer([:positive])}")
    Application.put_env(:dev_ide, :agent_auth_profile_root, tmp)

    on_exit(fn ->
      restore_root(prev_root)
      File.rm_rf(tmp)
    end)

    %{root: tmp}
  end

  test "missing owner profile dirs are created and injected", %{root: root} do
    workspace = %{id: "ws-1", name: "dalexandre-devide"}
    claude_dir = Path.join([root, "profiles", "dalexandre", "claude"])
    codex_dir = Path.join([root, "profiles", "dalexandre", "codex"])

    assert AuthProfile.env_for_workspace(workspace, :claude) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir
           }

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{
             "CODEX_HOME" => codex_dir
           }

    assert AuthProfile.env_for_workspace(workspace) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir,
             "CODEX_HOME" => codex_dir
           }

    assert File.dir?(claude_dir)
    assert File.dir?(codex_dir)

    assert File.read!(Path.join(claude_dir, "README.devide-profile")) =~
             "requires sign-in again"
  end

  test "owner profile dirs are shared by matching owner workspaces", %{root: root} do
    workspace = %{id: "ws-1", name: "sconde-test"}

    claude_dir = AuthProfile.ensure_named_profile_dir!("sconde", :claude)
    codex_dir = Path.join([root, "profiles", "sconde", "codex"])

    assert claude_dir == Path.join([root, "profiles", "sconde", "claude"])

    assert AuthProfile.env_for_workspace(workspace, :claude) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir
           }

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{
             "CODEX_HOME" => codex_dir
           }

    assert AuthProfile.env_for_workspace(workspace) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir,
             "CODEX_HOME" => codex_dir
           }

    assert File.read!(Path.join(claude_dir, "README.devide-profile")) =~
             "DevIDE owner auth home"
  end

  test "workspace keys are normalized from names and ids", %{root: root} do
    assert AuthProfile.workspace_key(%{name: "Sconde Devbox!"}) == "sconde-devbox"
    assert AuthProfile.workspace_key(%{id: "ws.SCONDE_1"}) == "ws.sconde_1"
    assert AuthProfile.workspace_key("sconde/test") == "sconde-test"
    assert AuthProfile.owner_key("sconde/test") == "sconde"

    dir = AuthProfile.ensure_named_profile_dir!("sconde/test", :codex)
    assert dir == Path.join([root, "profiles", "sconde-test", "codex"])
  end

  test "owner profiles replace old workspace dirs and global auth is not used", %{
    root: root
  } do
    workspace = %{id: "ws-1", name: "sconde-test"}

    File.mkdir_p!(Path.join([root, "workspaces", "sconde-test", "codex"]))
    File.mkdir_p!(Path.join([root, "sconde-test", "codex"]))

    owner_dir = Path.join([root, "profiles", "sconde", "codex"])

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{
             "CODEX_HOME" => owner_dir
           }

    assert File.dir?(owner_dir)
  end

  test "shell helper reports auth profile status and list", %{root: root} do
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    env = [{"DEVIDE_AGENT_AUTH_ROOT", root}]
    dir = Path.join([root, "profiles", "sconde", "codex"])

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "auth.json"), "{}")

    assert {status, 0} = System.cmd("bash", [script, "--status", "sconde"], env: env)
    assert status =~ "workspace: sconde"
    assert status =~ "claude: owner sconde profile not created yet, sign-in required"
    assert status =~ "codex: owner sconde profile signed in"
    assert status =~ "CODEX_HOME=#{dir}"

    assert {list, 0} = System.cmd("bash", [script, "--list"], env: env)
    assert list =~ "owner profiles"
    assert list =~ "sconde"
    assert list =~ "signed-in"
  end

  test "devide signin detects owner from current workspace", %{root: root} do
    devide = Path.expand("../../../scripts/devide", __DIR__)
    home = Path.join(root, "home")
    codex = Path.join([home, ".devide", "real-bins", "codex"])
    codex_dir = Path.join([root, "profiles", "sconde", "codex"])

    File.mkdir_p!(Path.dirname(codex))

    File.write!(codex, """
    #!/usr/bin/env bash
    printf 'CODEX_HOME=%s\\n' "${CODEX_HOME}"
    printf 'args=%s\\n' "$*"
    """)

    File.chmod!(codex, 0o755)

    env = [
      {"DEVIDE_AGENT_AUTH_ROOT", root},
      {"HOME", home},
      {"DEV_IDE_API_TOKEN", "token"},
      {"DEVIDE_WORKSPACE_ID", "ws-1"},
      {"DEVIDE_WORKSPACE_NAME", "Sconde-Test"},
      {"PATH", System.get_env("PATH") || "/usr/bin:/bin"}
    ]

    assert {output, 0} =
             System.cmd("bash", [devide, "agent", "auth", "signin", "codex"],
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "signing codex into owner profile: sconde (Sconde-Test)"
    assert output =~ "CODEX_HOME=#{codex_dir}"
    assert output =~ "args=login"
    assert File.dir?(codex_dir)
  end

  defp restore_root(nil), do: Application.delete_env(:dev_ide, :agent_auth_profile_root)
  defp restore_root(value), do: Application.put_env(:dev_ide, :agent_auth_profile_root, value)
end
