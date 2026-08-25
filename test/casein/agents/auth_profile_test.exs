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
    workspace = %{id: "ws-1", name: "dalexandre-casein"}

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

    assert File.read!(Path.join(claude_dir, "README.casein-profile")) =~
             "opt-in Casein owner auth home"
  end

  describe "owner_key/1" do
    test "prefers the manager's authoritative user over the workspace name" do
      # The name parse is a heuristic; `:user` is what the devbox manager
      # actually recorded. When they disagree, the manager wins.
      assert AuthProfile.owner_key(%{id: "ws-1", name: "farm-parity-fields", user: "rgomez"}) ==
               "rgomez"

      assert AuthProfile.owner_key(%{
               id: "ws-1",
               name: "shared-thing",
               metadata: %{user: "mtinker"}
             }) == "mtinker"
    end

    test "falls back to the name prefix when the manager set no user" do
      # Local-source workspaces carry `user: nil`.
      assert AuthProfile.owner_key(%{id: "ws-1", name: "sconde-test", user: nil}) == "sconde"
    end

    test "a bare workspace id resolves to no owner at all" do
      # Regression: the name parse used to reduce a UUID to its first hex
      # group, so callers passing a workspace id resolved a principal like
      # "e7c18b93" and looked up a profile dir that can never exist.
      assert AuthProfile.owner_key("e7c18b93-688b-4bb0-904d-ac93d61e9372") == nil
      assert AuthProfile.owner_key(%{id: "e7c18b93-688b-4bb0-904d-ac93d61e9372"}) == nil

      assert AuthProfile.active_profile_dir("e7c18b93-688b-4bb0-904d-ac93d61e9372", :claude) ==
               nil
    end
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
    gh_dir = Path.join([root, "profiles", "sconde", "gh"])

    assert AuthProfile.env_for_workspace(workspace) == %{
             "CLAUDE_CONFIG_DIR" => claude_dir,
             "CODEX_HOME" => codex_dir,
             "GH_CONFIG_DIR" => gh_dir
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
    env = [{"CASEIN_AGENT_AUTH_ROOT", root}]
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
    assert list =~ "principal profiles"
    assert list =~ "sconde"
    assert list =~ "signed-in"
  end

  describe "per-runtime registration" do
    test "an entry may scope fail-closed to some runtimes", %{root: root} do
      # sconde has provider accounts but no GitHub account on this box. Failing
      # their gh closed would break them to protect an identity they do not
      # have; claude and codex must stay strict regardless.
      File.mkdir_p!(root)

      File.write!(Path.join(root, "owners"), """
      # team owners
      dalexandre
      sconde:claude,codex
      """)

      assert AuthProfile.registered_principal?("sconde", :claude)
      assert AuthProfile.registered_principal?("sconde", :codex)
      refute AuthProfile.registered_principal?("sconde", :gh)

      # A bare slug still covers everything — every pre-existing entry.
      assert AuthProfile.registered_principal?("dalexandre", :gh)
      assert AuthProfile.registered_runtimes("dalexandre") == :all
      assert AuthProfile.registered_runtimes("sconde") == [:claude, :codex]
      assert AuthProfile.registered_runtimes("nobody") == []
    end

    test "a scoped entry only fails closed for its own runtimes", %{root: root} do
      File.mkdir_p!(root)
      File.write!(Path.join(root, "owners"), "sconde:claude\n")

      claude_dir = Path.join([root, "profiles", "sconde", "claude"])

      # claude: registered, so the (empty) profile applies and the CLI must
      # sign in there rather than borrow the host login.
      assert AuthProfile.env_for_principal("sconde", :claude) == %{
               "CLAUDE_CONFIG_DIR" => claude_dir
             }

      # gh: not registered and not signed in, so it stays on global auth.
      assert AuthProfile.env_for_principal("sconde", :gh) == %{}
    end

    test "an unknown runtime name is dropped, not fatal", %{root: root} do
      # The file is hand-edited; a typo must not take down every launch.
      File.mkdir_p!(root)
      File.write!(Path.join(root, "owners"), "sconde:claude,nonsense\n")

      assert AuthProfile.registered_runtimes("sconde") == [:claude]
      assert AuthProfile.registered_principal?("sconde", :claude)
      refute AuthProfile.registered_principal?("sconde", :codex)
    end
  end

  test "shell helper scopes registration per runtime", %{root: root} do
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    env = [{"CASEIN_AGENT_AUTH_ROOT", root}]

    assert {_out, 0} =
             System.cmd("bash", [script, "--register", "sconde", "claude,codex"], env: env)

    assert File.read!(Path.join(root, "owners")) =~ "sconde:claude,codex"

    assert {_out, 0} = System.cmd("bash", [script, "--registered", "sconde", "claude"], env: env)
    assert {_out, code} = System.cmd("bash", [script, "--registered", "sconde", "gh"], env: env)
    refute code == 0

    # Re-registering replaces the entry; appending would let the first match
    # win forever and silently ignore the narrowed scope.
    assert {_out, 0} = System.cmd("bash", [script, "--register", "sconde", "claude"], env: env)
    owners = File.read!(Path.join(root, "owners"))
    assert owners =~ "sconde:claude\n"
    refute owners =~ "claude,codex"

    assert {_out, code} = System.cmd("bash", [script, "--register", "sconde", "bogus"], env: env)
    refute code == 0
  end

  test "shell helper resolves CASEIN_ACTOR ahead of the workspace owner", %{root: root} do
    # The shell mirror and `Casein.Identity` must agree about who an agent is;
    # if they drift, a pane's Claude home and its GH_CONFIG_DIR name different
    # people.
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    base = [{"CASEIN_AGENT_AUTH_ROOT", root}]

    for runtime <- ~w(claude codex gh) do
      File.mkdir_p!(Path.join([root, "profiles", "jgiles", runtime]))
    end

    File.write!(Path.join([root, "profiles", "jgiles", "gh", "hosts.yml"]), "github.com:\n")

    # No actor: the workspace owner still wins, as before.
    assert {dir, 0} =
             System.cmd("bash", [script, "--dir", "dalexandre-devide", "gh"], env: base)

    assert String.trim(dir) == Path.join([root, "profiles", "dalexandre", "gh"])

    # With an actor, the viewer's own profile is used in someone else's
    # workspace — no borrowing the owner's GitHub account.
    env = [{"CASEIN_ACTOR", "jgiles"} | base]

    assert {dir, 0} = System.cmd("bash", [script, "--dir", "dalexandre-devide", "gh"], env: env)
    assert String.trim(dir) == Path.join([root, "profiles", "jgiles", "gh"])

    assert {pairs, 0} =
             System.cmd("bash", [script, "--pairs", "dalexandre-devide", "gh"], env: env)

    assert String.trim(pairs) ==
             "GH_CONFIG_DIR\t#{Path.join([root, "profiles", "jgiles", "gh"])}"
  end

  test "shell helper refuses to derive a principal from a workspace id", %{root: root} do
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    env = [{"CASEIN_AGENT_AUTH_ROOT", root}]

    assert {_out, code} =
             System.cmd(
               "bash",
               [script, "--dir", "e7c18b93-688b-4bb0-904d-ac93d61e9372", "claude"],
               env: env,
               stderr_to_stdout: true
             )

    refute code == 0
  end

  test "shell helper registers and unregisters fail-closed owners", %{root: root} do
    script = Path.expand("../../../scripts/lib/agent-auth-profile.sh", __DIR__)
    env = [{"CASEIN_AGENT_AUTH_ROOT", root}]

    assert {out, 0} = System.cmd("bash", [script, "--register", "sconde"], env: env)
    assert out =~ "registered sconde for: all runtimes"
    assert File.dir?(Path.join([root, "profiles", "sconde", "claude"]))
    assert File.dir?(Path.join([root, "profiles", "sconde", "codex"]))

    # Registered + not signed in: env pairs point at the empty profile.
    assert {pairs, 0} = System.cmd("bash", [script, "--pairs", "sconde-test", "claude"], env: env)
    assert pairs =~ "CLAUDE_CONFIG_DIR\t#{Path.join([root, "profiles", "sconde", "claude"])}"

    assert {status, 0} = System.cmd("bash", [script, "--status", "sconde-test"], env: env)
    assert status =~ "registered owner sconde — sign-in required, global fallback disabled"

    assert {list, 0} = System.cmd("bash", [script, "--list"], env: env)
    # The column now names the registered runtimes rather than yes/no.
    assert list =~ ~r/sconde\s+all/

    assert {_, 0} = System.cmd("bash", [script, "--registered", "sconde"], env: env)
    assert {_, 1} = System.cmd("bash", [script, "--registered", "tramzel"], env: env)

    assert {out, 0} = System.cmd("bash", [script, "--unregister", "sconde"], env: env)
    assert out =~ "unregistered owner sconde"

    assert {pairs, 0} = System.cmd("bash", [script, "--pairs", "sconde-test", "claude"], env: env)
    assert pairs == ""

    # CASEIN_AGENT_AUTH_FALLBACK=none treats every owner as registered.
    none_env = [{"CASEIN_AGENT_AUTH_FALLBACK", "none"} | env]

    assert {pairs, 0} =
             System.cmd("bash", [script, "--pairs", "tramzel-ws", "codex"], env: none_env)

    assert pairs =~ "CODEX_HOME\t#{Path.join([root, "profiles", "tramzel", "codex"])}"
  end

  test "casein signin detects owner from current workspace", %{root: root} do
    casein = Path.expand("../../../scripts/casein", __DIR__)
    home = Path.join(root, "home")
    codex = Path.join([home, ".casein", "real-bins", "codex"])
    codex_dir = Path.join([root, "profiles", "sconde", "codex"])

    File.mkdir_p!(Path.dirname(codex))

    File.write!(codex, """
    #!/usr/bin/env bash
    printf 'CODEX_HOME=%s\\n' "${CODEX_HOME}"
    printf 'args=%s\\n' "$*"
    """)

    File.chmod!(codex, 0o755)

    # System.cmd/3 merges `env:` into the BEAM process environment on the devbox,
    # so leaked CASEIN_SCRIPTS/CODEX_HOME from tmux would invoke the real provider
    # CLI (OAuth hang). env -i keeps only the vars this test needs.
    signin_env = [
      {"CASEIN_AGENT_AUTH_ROOT", root},
      {"CASEIN_SCRIPTS", Path.dirname(casein)},
      {"HOME", home},
      {"CASEIN_API_TOKEN", "token"},
      {"CASEIN_WORKSPACE_ID", "ws-1"},
      {"CASEIN_WORKSPACE_NAME", "Sconde-Test"},
      {"PATH", "/usr/bin:/bin"},
      {"SHELL", "/bin/bash"},
      {"LANG", "C.UTF-8"}
    ]

    env_args = Enum.flat_map(signin_env, fn {key, value} -> ["#{key}=#{value}"] end)

    assert {output, 0} =
             System.cmd(
               "env",
               ["-i" | env_args ++ ["bash", casein, "agent", "auth", "signin", "codex"]],
               stderr_to_stdout: true
             )

    assert output =~ "signing codex into profile: sconde (Sconde-Test)"
    assert output =~ "CODEX_HOME=#{codex_dir}"
    assert output =~ "args=login"
    assert File.dir?(codex_dir)
  end

  defp sign_in!(dir, :claude), do: File.write!(Path.join(dir, ".credentials.json"), "{}")
  defp sign_in!(dir, :codex), do: File.write!(Path.join(dir, "auth.json"), "{}")

  defp restore_root(nil), do: Application.delete_env(:casein, :agent_auth_profile_root)
  defp restore_root(value), do: Application.put_env(:casein, :agent_auth_profile_root, value)
end
