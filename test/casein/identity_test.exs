defmodule Casein.IdentityTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AuthProfile
  alias Casein.Identity

  setup do
    prev_root = Application.get_env(:casein, :agent_auth_profile_root)
    prev_domain = Application.get_env(:casein, :forward_auth_email_domain)
    prev_service = Application.get_env(:casein, :gh_service_config_dir)
    prev_actor = System.get_env("CASEIN_ACTOR")

    tmp = Path.join(System.tmp_dir!(), "identity-#{System.unique_integer([:positive])}")
    Application.put_env(:casein, :agent_auth_profile_root, tmp)
    Application.put_env(:casein, :forward_auth_email_domain, "milcgroup.com")
    Application.delete_env(:casein, :gh_service_config_dir)
    System.delete_env("CASEIN_ACTOR")

    on_exit(fn ->
      restore(:agent_auth_profile_root, prev_root)
      restore(:forward_auth_email_domain, prev_domain)
      restore(:gh_service_config_dir, prev_service)

      case prev_actor do
        nil -> System.delete_env("CASEIN_ACTOR")
        value -> System.put_env("CASEIN_ACTOR", value)
      end

      File.rm_rf(tmp)
    end)

    %{root: tmp}
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp sign_in!(principal, runtime) do
    dir = AuthProfile.ensure_named_profile_dir!(principal, runtime)
    marker = %{claude: ".credentials.json", codex: "auth.json", gh: "hosts.yml"}
    File.write!(Path.join(dir, Map.fetch!(marker, runtime)), "{}")
    dir
  end

  defp viewer(username),
    do: %{id: username, username: username, email: "#{username}@milcgroup.com"}

  describe "resolution order" do
    test "the viewer wins over the workspace owner" do
      # The whole point of the change: working in a colleague's workspace must
      # not spend the colleague's identity.
      identity =
        Identity.resolve(
          viewer: viewer("jgiles"),
          workspace: %{id: "ws-1", name: "dalexandre-devide", user: "dalexandre"}
        )

      assert identity.principal == "jgiles"
      assert identity.source == :viewer
    end

    test "an explicit principal wins over everything" do
      identity =
        Identity.resolve(
          principal: "sconde",
          viewer: viewer("jgiles"),
          workspace: %{id: "ws-1", name: "dalexandre-devide", user: "dalexandre"}
        )

      assert identity.principal == "sconde"
      assert identity.source == :explicit
    end

    test "CASEIN_ACTOR is used when there is no viewer" do
      System.put_env("CASEIN_ACTOR", "mtinker")

      identity = Identity.resolve(workspace: %{id: "ws-1", name: "dalexandre-devide"})

      assert identity.principal == "mtinker"
      assert identity.source == :env
    end

    test "env: false ignores CASEIN_ACTOR" do
      # Server-side callers must not inherit a principal from the beam's own
      # environment — that would stamp every workspace on the box with one
      # identity.
      System.put_env("CASEIN_ACTOR", "mtinker")

      identity =
        Identity.resolve(workspace: %{id: "ws-1", name: "dalexandre-devide"}, env: false)

      assert identity.principal == "dalexandre"
      assert identity.source == :workspace
    end

    test "the workspace is the last resort" do
      identity = Identity.resolve(workspace: %{id: "ws-1", name: "sconde-test"})

      assert identity.principal == "sconde"
      assert identity.source == :workspace
    end

    test "nothing resolvable leaves the principal unset" do
      identity = Identity.resolve()

      assert identity.principal == nil
      assert identity.source == :unresolved
      assert Identity.env(identity) == %{}
      assert Identity.git_author(identity) == nil
      assert Identity.git_config_args(identity) == []
    end
  end

  describe "viewer shapes" do
    test "accepts atom keys, string keys, and a bare email" do
      for v <- [
            %{username: "jgiles"},
            %{"username" => "jgiles"},
            %{id: "jgiles"},
            %{email: "JGiles@milcgroup.com"},
            "jgiles@milcgroup.com"
          ] do
        assert Identity.resolve(viewer: v).principal == "jgiles"
      end
    end

    test "an empty viewer map falls through rather than resolving to nothing-in-particular" do
      identity = Identity.resolve(viewer: %{}, workspace: %{id: "w", name: "sconde-test"})

      assert identity.principal == "sconde"
    end
  end

  describe "env/1" do
    test "exports only the runtimes that have an active profile", %{root: root} do
      sign_in!("jgiles", :claude)
      sign_in!("jgiles", :gh)

      env = Identity.env(viewer: viewer("jgiles"), env: false)

      assert env["CLAUDE_CONFIG_DIR"] == Path.join([root, "profiles", "jgiles", "claude"])
      assert env["GH_CONFIG_DIR"] == Path.join([root, "profiles", "jgiles", "gh"])
      assert env["CASEIN_ACTOR"] == "jgiles"
      assert env["CASEIN_ACTOR_EMAIL"] == "jgiles@milcgroup.com"

      # Codex was never signed in here: the key is absent, so the launch keeps
      # whatever the host global login provides instead of pointing at an
      # empty directory.
      refute Map.has_key?(env, "CODEX_HOME")
    end

    test "a registered principal fails closed before sign-in", %{root: root} do
      File.mkdir_p!(root)
      File.write!(Path.join(root, "owners"), "tramzel\n")

      env = Identity.env(principal: "tramzel", env: false)

      assert env["GH_CONFIG_DIR"] == Path.join([root, "profiles", "tramzel", "gh"])
      assert env["CLAUDE_CONFIG_DIR"] == Path.join([root, "profiles", "tramzel", "claude"])
    end
  end

  describe "gh_env/1" do
    test "blanks ambient tokens" do
      # An ambient GH_TOKEN silently outranks GH_CONFIG_DIR, so a correctly
      # resolved profile would be ignored without this.
      env = Map.new(Identity.gh_env(env: false))

      assert env["GH_TOKEN"] == ""
      assert env["GITHUB_TOKEN"] == ""
    end

    test "prefers the principal's profile over the service identity", %{root: root} do
      sign_in!("jgiles", :gh)
      Application.put_env(:casein, :gh_service_config_dir, "/srv/gh")

      env = Map.new(Identity.gh_env(viewer: viewer("jgiles"), env: false))

      assert env["GH_CONFIG_DIR"] == Path.join([root, "profiles", "jgiles", "gh"])
    end

    test "falls back to a declared service identity, never a personal one" do
      Application.put_env(:casein, :gh_service_config_dir, "/srv/gh")

      env = Map.new(Identity.gh_env(env: false))

      assert env["GH_CONFIG_DIR"] == "/srv/gh"
    end

    test "with nothing declared it omits GH_CONFIG_DIR entirely" do
      # Regression guard: both server-side gh callers used to default to one
      # engineer's config dir, so ticket reads and claim writes were attributed
      # to them regardless of who triggered the action.
      prev = System.get_env("GH_CONFIG_DIR")
      System.delete_env("GH_CONFIG_DIR")
      on_exit(fn -> if prev, do: System.put_env("GH_CONFIG_DIR", prev) end)

      env = Map.new(Identity.gh_env(env: false))

      refute Map.has_key?(env, "GH_CONFIG_DIR")
    end
  end

  describe "git identity" do
    test "uses the viewer's real email, not a synthesized one" do
      identity = Identity.resolve(viewer: %{username: "jgiles", email: "j.giles@example.org"})

      assert Identity.git_author(identity) == {"jgiles", "j.giles@example.org"}
    end

    test "synthesizes from the forward-auth domain when there is no viewer email" do
      assert Identity.git_author(principal: "sconde", env: false) ==
               {"sconde", "sconde@milcgroup.com"}
    end

    test "git_config_args are empty without a domain so git keeps its own config" do
      Application.delete_env(:casein, :forward_auth_email_domain)
      prev = System.get_env("CASEIN_FORWARD_AUTH_EMAIL_DOMAIN")
      System.delete_env("CASEIN_FORWARD_AUTH_EMAIL_DOMAIN")
      on_exit(fn -> if prev, do: System.put_env("CASEIN_FORWARD_AUTH_EMAIL_DOMAIN", prev) end)

      assert Identity.git_config_args(principal: "sconde", env: false) == []
    end

    test "git_config_args produce per-invocation flags" do
      assert Identity.git_config_args(principal: "sconde", env: false) ==
               ["-c", "user.name=sconde", "-c", "user.email=sconde@milcgroup.com"]
    end
  end
end
