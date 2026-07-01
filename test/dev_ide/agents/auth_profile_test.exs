defmodule DevIDE.Agents.AuthProfileTest do
  use ExUnit.Case, async: false

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

  test "missing profile dirs leave provider auth global", %{root: root} do
    workspace = %{id: "ws-1", name: "dalexandre-devide"}

    assert AuthProfile.env_for_workspace(workspace, :claude) == %{}
    assert AuthProfile.env_for_workspace(workspace, :codex) == %{}
    assert AuthProfile.env_for_workspace(workspace) == %{}

    refute File.exists?(Path.join([root, "workspaces", "dalexandre-devide", "claude"]))
    refute File.exists?(Path.join([root, "workspaces", "dalexandre-devide", "codex"]))
  end

  test "existing profile dirs activate only their runtime env vars", %{root: root} do
    workspace = %{id: "ws-1", name: "sconde-test"}

    claude_dir = AuthProfile.ensure_profile_dir!(workspace, :claude)

    assert claude_dir == Path.join([root, "workspaces", "sconde-test", "claude"])

    assert AuthProfile.env_for_workspace(workspace, :claude) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir
           }

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{}

    codex_dir = AuthProfile.ensure_profile_dir!(workspace, :codex)

    assert AuthProfile.env_for_workspace(workspace) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir,
             "CODEX_HOME" => codex_dir
           }

    assert File.read!(Path.join(claude_dir, "README.devide-profile")) =~
             "workspace-scoped auth home"
  end

  test "workspace keys are normalized from names and ids", %{root: root} do
    assert AuthProfile.workspace_key(%{name: "Sconde Devbox!"}) == "sconde-devbox"
    assert AuthProfile.workspace_key(%{id: "ws.SCONDE_1"}) == "ws.sconde_1"
    assert AuthProfile.workspace_key("sconde/test") == "sconde-test"
    assert AuthProfile.owner_key("sconde/test") == "sconde"

    dir = AuthProfile.ensure_profile_dir!("sconde/test", :codex)
    assert dir == Path.join([root, "workspaces", "sconde-test", "codex"])
  end

  test "shared owner profiles override global auth and can be overridden per workspace", %{
    root: root
  } do
    workspace = %{id: "ws-1", name: "sconde-test"}

    owner_dir = AuthProfile.ensure_named_profile_dir!("sconde", :codex)
    assert owner_dir == Path.join([root, "profiles", "sconde", "codex"])

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{
             "CODEX_HOME" => owner_dir
           }

    workspace_dir = AuthProfile.ensure_profile_dir!(workspace, :codex)

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{
             "CODEX_HOME" => workspace_dir
           }
  end

  test "shell helper reports auth profile status and list", %{root: root} do
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    env = [{"DEVIDE_AGENT_AUTH_ROOT", root}]

    assert {dir, 0} = System.cmd("bash", [script, "--ensure", "sconde", "codex"], env: env)
    assert String.trim(dir) == Path.join([root, "workspaces", "sconde", "codex"])

    assert {status, 0} = System.cmd("bash", [script, "--status", "sconde"], env: env)
    assert status =~ "workspace: sconde"
    assert status =~ "claude: global auth"
    assert status =~ "codex: workspace profile"
    assert status =~ "CODEX_HOME=#{Path.join([root, "workspaces", "sconde", "codex"])}"

    assert {list, 0} = System.cmd("bash", [script, "--list"], env: env)
    assert list =~ "workspace"
    assert list =~ "sconde"
    assert list =~ "global"
    assert list =~ "profile"
  end

  test "shell helper applies shared profiles", %{root: root} do
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    env = [{"DEVIDE_AGENT_AUTH_ROOT", root}]

    assert {shared_dir, 0} =
             System.cmd("bash", [script, "--ensure-named", "sconde", "codex"], env: env)

    assert String.trim(shared_dir) == Path.join([root, "profiles", "sconde", "codex"])

    assert {owner_status, 0} = System.cmd("bash", [script, "--status", "sconde-test"], env: env)
    assert owner_status =~ "codex: shared sconde profile"
    assert owner_status =~ "CODEX_HOME=#{Path.join([root, "profiles", "sconde", "codex"])}"

    assert {link, 0} =
             System.cmd("bash", [script, "--use-named", "custom-ws", "sconde", "codex"], env: env)

    assert String.trim(link) == Path.join([root, "workspaces", "custom-ws", "codex"])

    assert {status, 0} = System.cmd("bash", [script, "--status", "custom-ws"], env: env)
    assert status =~ "codex: shared sconde profile"
    assert status =~ "CODEX_HOME=#{Path.join([root, "workspaces", "custom-ws", "codex"])}"

    old_dir = Path.join([root, "workspaces", "replace-ws", "codex"])
    File.mkdir_p!(old_dir)
    File.write!(Path.join(old_dir, "token.json"), "old-profile")

    assert {replace_link, 0} =
             System.cmd("bash", [script, "--use-named", "replace-ws", "sconde", "codex"],
               env: env
             )

    assert String.trim(replace_link) == old_dir
    assert File.read_link!(old_dir) == Path.join([root, "profiles", "sconde", "codex"])

    assert [backup_dir] = Path.wildcard("#{old_dir}.backup-*")
    assert File.read!(Path.join(backup_dir, "token.json")) == "old-profile"
  end

  defp restore_root(nil), do: Application.delete_env(:dev_ide, :agent_auth_profile_root)
  defp restore_root(value), do: Application.put_env(:dev_ide, :agent_auth_profile_root, value)
end
