defmodule Casein.Agents.AuthProfileTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AuthProfile

  setup do
    prev_root = Application.get_env(:casein, :agent_auth_profile_root)
    tmp = Path.join(System.tmp_dir!(), "agent-auth-profile-#{System.unique_integer([:positive])}")
    Application.put_env(:casein, :agent_auth_profile_root, tmp)

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

    refute File.exists?(Path.join([root, "profiles", "dalexandre", "claude"]))
    refute File.exists?(Path.join([root, "profiles", "dalexandre", "codex"]))
  end

  test "signed-in owner profiles are shared by matching owner workspaces", %{root: root} do
    workspace = %{id: "ws-1", name: "sconde-test"}

    claude_dir = AuthProfile.ensure_named_profile_dir!("sconde", :claude)

    assert claude_dir == Path.join([root, "profiles", "sconde", "claude"])

    # A profile dir without completed credentials keeps global auth.
    refute AuthProfile.signed_in?(claude_dir, :claude)
    assert AuthProfile.env_for_workspace(workspace, :claude) == %{}

    sign_in!(claude_dir, :claude)

    assert AuthProfile.env_for_workspace(workspace, :claude) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir
           }

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{}

    codex_dir = AuthProfile.ensure_named_profile_dir!("sconde", :codex)

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{}

    sign_in!(codex_dir, :codex)

    assert AuthProfile.env_for_workspace(workspace) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir,
             "CODEX_HOME" => codex_dir
           }

    assert File.read!(Path.join(claude_dir, "README.devide-profile")) =~
             "opt-in Casein owner auth home"
  end

  test "registered owners fail closed before sign-in", %{root: root} do
    workspace = %{id: "ws-1", name: "sconde-test"}

    File.mkdir_p!(root)

    File.write!(Path.join(root, "owners"), """
    # team owners
    sconde
      mbaldin   # trailing comment
    """)

    assert AuthProfile.registered_owner?(workspace)
    assert AuthProfile.registered_owner?("mbaldin-widget")
    refute AuthProfile.registered_owner?("tramzel-widget")

    # No sign-in yet: the profile dir still applies, so the provider CLI
    # prompts for its own login instead of using global auth.
    claude_dir = Path.join([root, "profiles", "sconde", "claude"])
    codex_dir = Path.join([root, "profiles", "sconde", "codex"])

    assert AuthProfile.env_for_workspace(workspace) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir,
             "CODEX_HOME" => codex_dir
           }

    assert AuthProfile.env_for_workspace(%{id: "ws-2", name: "tramzel-widget"}) == %{}
  end

  test "workspace keys are normalized from names and ids", %{root: root} do
    assert AuthProfile.workspace_key(%{name: "Sconde Devbox!"}) == "sconde-devbox"
    assert AuthProfile.workspace_key(%{id: "ws.SCONDE_1"}) == "ws.sconde_1"
    assert AuthProfile.workspace_key("sconde/test") == "sconde-test"
    assert AuthProfile.owner_key("sconde/test") == "sconde"

    dir = AuthProfile.ensure_named_profile_dir!("sconde/test", :codex)
    assert dir == Path.join([root, "profiles", "sconde-test", "codex"])
  end

  test "signed-in owner profiles replace global auth and old workspace dirs are ignored", %{
    root: root
  } do
    workspace = %{id: "ws-1", name: "sconde-test"}

    File.mkdir_p!(Path.join([root, "workspaces", "sconde-test", "codex"]))
    File.mkdir_p!(Path.join([root, "sconde-test", "codex"]))

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{}

    owner_dir = AuthProfile.ensure_named_profile_dir!("sconde", :codex)
    assert owner_dir == Path.join([root, "profiles", "sconde", "codex"])
    sign_in!(owner_dir, :codex)

    assert AuthProfile.env_for_workspace(workspace, :codex) == %{
             "CODEX_HOME" => owner_dir
           }
  end

  test "shell helper reports auth profile status and list", %{root: root} do
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    env = [{"DEVIDE_AGENT_AUTH_ROOT", root}]
    dir = Path.join([root, "profiles", "sconde", "codex"])

    File.mkdir_p!(dir)

    # Profile dir without credentials: still global auth.
    assert {status, 0} = System.cmd("bash", [script, "--status", "sconde"], env: env)
    assert status =~ "claude: global auth — no owner sconde profile"
    assert status =~ "codex: global auth — owner sconde profile exists but is not signed in"

    assert {list, 0} = System.cmd("bash", [script, "--list"], env: env)
    assert list =~ "sign-in-required"

    File.write!(Path.join(dir, "auth.json"), "{}")

    assert {status, 0} = System.cmd("bash", [script, "--status", "sconde"], env: env)
    assert status =~ "workspace: sconde"
    assert status =~ "codex: owner sconde profile signed in"
    assert status =~ "CODEX_HOME=#{dir}"

    assert {list, 0} = System.cmd("bash", [script, "--list"], env: env)
    assert list =~ "owner profiles"
    assert list =~ "sconde"
    assert list =~ "signed-in"
  end

  test "shell helper registers and unregisters fail-closed owners", %{root: root} do
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    env = [{"DEVIDE_AGENT_AUTH_ROOT", root}]

    assert {out, 0} = System.cmd("bash", [script, "--register", "sconde"], env: env)
    assert out =~ "registered owner sconde"
    assert File.dir?(Path.join([root, "profiles", "sconde", "claude"]))
    assert File.dir?(Path.join([root, "profiles", "sconde", "codex"]))

    # Registered + not signed in: env pairs point at the empty profile.
    assert {pairs, 0} = System.cmd("bash", [script, "--pairs", "sconde-test", "claude"], env: env)
    assert pairs =~ "CLAUDE_CONFIG_DIR\t#{Path.join([root, "profiles", "sconde", "claude"])}"

    assert {status, 0} = System.cmd("bash", [script, "--status", "sconde-test"], env: env)
    assert status =~ "registered owner sconde — sign-in required, global fallback disabled"

    assert {list, 0} = System.cmd("bash", [script, "--list"], env: env)
    assert list =~ ~r/sconde\s+yes/

    assert {_, 0} = System.cmd("bash", [script, "--registered", "sconde"], env: env)
    assert {_, 1} = System.cmd("bash", [script, "--registered", "tramzel"], env: env)

    assert {out, 0} = System.cmd("bash", [script, "--unregister", "sconde"], env: env)
    assert out =~ "unregistered owner sconde"

    assert {pairs, 0} = System.cmd("bash", [script, "--pairs", "sconde-test", "claude"], env: env)
    assert pairs == ""

    # DEVIDE_AGENT_AUTH_FALLBACK=none treats every owner as registered.
    none_env = [{"DEVIDE_AGENT_AUTH_FALLBACK", "none"} | env]

    assert {pairs, 0} =
             System.cmd("bash", [script, "--pairs", "tramzel-ws", "codex"], env: none_env)

    assert pairs =~ "CODEX_HOME\t#{Path.join([root, "profiles", "tramzel", "codex"])}"
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

    # System.cmd/3 merges `env:` into the BEAM process environment on the devbox,
    # so leaked DEVIDE_SCRIPTS/CODEX_HOME from tmux would invoke the real provider
    # CLI (OAuth hang). env -i keeps only the vars this test needs.
    signin_env = [
      {"DEVIDE_AGENT_AUTH_ROOT", root},
      {"DEVIDE_SCRIPTS", Path.dirname(devide)},
      {"HOME", home},
      {"DEV_IDE_API_TOKEN", "token"},
      {"DEVIDE_WORKSPACE_ID", "ws-1"},
      {"DEVIDE_WORKSPACE_NAME", "Sconde-Test"},
      {"PATH", "/usr/bin:/bin"},
      {"SHELL", "/bin/bash"},
      {"LANG", "C.UTF-8"}
    ]

    env_args = Enum.flat_map(signin_env, fn {key, value} -> ["#{key}=#{value}"] end)

    assert {output, 0} =
             System.cmd(
               "env",
               ["-i" | env_args ++ ["bash", devide, "agent", "auth", "signin", "codex"]],
               stderr_to_stdout: true
             )

    assert output =~ "signing codex into owner profile: sconde (Sconde-Test)"
    assert output =~ "CODEX_HOME=#{codex_dir}"
    assert output =~ "args=login"
    assert File.dir?(codex_dir)
  end

  defp sign_in!(dir, :claude), do: File.write!(Path.join(dir, ".credentials.json"), "{}")
  defp sign_in!(dir, :codex), do: File.write!(Path.join(dir, "auth.json"), "{}")

  defp restore_root(nil), do: Application.delete_env(:casein, :agent_auth_profile_root)
  defp restore_root(value), do: Application.put_env(:casein, :agent_auth_profile_root, value)
end
