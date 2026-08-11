defmodule Casein.PathsTest do
  use ExUnit.Case, async: false

  alias Casein.Paths

  setup do
    prev_home_dir = Application.get_env(:casein, :home_dir)
    prev_roots = Application.get_env(:casein, :agent_worktree_roots)
    prev_home = System.get_env("HOME")
    prev_profile = System.get_env("USERPROFILE")
    prev_env_roots = System.get_env("CASEIN_AGENT_WORKTREE_ROOTS")

    on_exit(fn ->
      restore_app(:home_dir, prev_home_dir)
      restore_app(:agent_worktree_roots, prev_roots)
      restore_env("HOME", prev_home)
      restore_env("USERPROFILE", prev_profile)
      restore_env("CASEIN_AGENT_WORKTREE_ROOTS", prev_env_roots)
    end)

    :ok
  end

  test "home/0 prefers the :home_dir application override" do
    Application.put_env(:casein, :home_dir, "/tmp/casein-home-override")
    System.put_env("HOME", "/tmp/should-not-win")

    assert Paths.home() == "/tmp/casein-home-override"
    assert Paths.home!() == "/tmp/casein-home-override"
  end

  test "home/0 uses HOME then USERPROFILE without a host-specific fallback" do
    Application.delete_env(:casein, :home_dir)
    System.put_env("HOME", "/tmp/portable-home")
    System.delete_env("USERPROFILE")

    assert Paths.home() == "/tmp/portable-home"

    System.delete_env("HOME")
    System.put_env("USERPROFILE", "C:/Users/portable")

    assert Paths.home() == "C:/Users/portable"
  end

  test "home!/0 raises when no home can be resolved" do
    # Pin an empty override so present?/1 rejects it, then clear env. On hosts
    # where System.user_home/0 still resolves, home!/0 succeeds with that value
    # — which is still portable (no invented path). When it does not, home!/0
    # must raise rather than invent a host-specific fallback.
    Application.put_env(:casein, :home_dir, "")
    System.delete_env("HOME")
    System.delete_env("USERPROFILE")

    case Paths.home() do
      nil ->
        assert_raise ArgumentError, ~r/HOME or USERPROFILE is required/, fn ->
          Paths.home!()
        end

      home when is_binary(home) ->
        assert Paths.home!() == home
        assert home == System.user_home()
    end
  end

  test "default_agent_worktree_roots/0 is tmp + home-relative, never host literals" do
    Application.put_env(:casein, :home_dir, "/tmp/casein-paths-home")
    System.delete_env("CASEIN_AGENT_WORKTREE_ROOTS")
    Application.delete_env(:casein, :agent_worktree_roots)

    roots = Paths.default_agent_worktree_roots()
    tmp_root = Path.join(System.tmp_dir!(), "casein-agent-worktrees")

    assert tmp_root in roots
    assert Path.join("/tmp/casein-paths-home", ".local/share/opencode") in roots
    assert Path.join("/tmp/casein-paths-home", ".local/share/codex") in roots
    assert Path.join("/tmp/casein-paths-home", ".cache/codex") in roots
    assert Path.join("/tmp/casein-paths-home", ".claude") in roots

    refute Enum.any?(roots, &String.contains?(&1, "/data/casein-agent-worktrees"))
    refute Enum.any?(roots, &String.contains?(&1, "/data/workspaces/dalexandre"))
    refute Enum.any?(roots, &String.contains?(&1, "/home/devbox"))
  end

  test "configured_agent_worktree_roots/0 reads app env then CASEIN_AGENT_WORKTREE_ROOTS" do
    Application.put_env(:casein, :agent_worktree_roots, ["/tmp/app-wt-root"])
    System.put_env("CASEIN_AGENT_WORKTREE_ROOTS", "/tmp/env-wt-a:/tmp/env-wt-b")

    roots = Paths.configured_agent_worktree_roots()

    assert Path.expand("/tmp/app-wt-root") in roots
    assert Path.expand("/tmp/env-wt-a") in roots
    assert Path.expand("/tmp/env-wt-b") in roots
  end

  test "agent_worktree_roots/0 prefers configured roots over defaults" do
    Application.put_env(:casein, :agent_worktree_roots, ["/tmp/only-configured"])
    System.delete_env("CASEIN_AGENT_WORKTREE_ROOTS")

    assert Paths.agent_worktree_roots() == [Path.expand("/tmp/only-configured")]
  end

  test "agent_worktree_roots/0 falls back to portable defaults when unconfigured" do
    Application.put_env(:casein, :agent_worktree_roots, [])
    System.delete_env("CASEIN_AGENT_WORKTREE_ROOTS")
    Application.put_env(:casein, :home_dir, "/tmp/fallback-home")

    roots = Paths.agent_worktree_roots()
    tmp_root = Path.join(System.tmp_dir!(), "casein-agent-worktrees")

    assert tmp_root in roots
    assert Path.join("/tmp/fallback-home", ".claude") in roots
  end

  test "agent_worktree_admission_roots/1 concatenates configured, extra, and defaults" do
    Application.put_env(:casein, :agent_worktree_roots, ["/tmp/admit-cfg"])
    System.delete_env("CASEIN_AGENT_WORKTREE_ROOTS")
    Application.put_env(:casein, :home_dir, "/tmp/admit-home")

    roots =
      Paths.agent_worktree_admission_roots(extra: ["/tmp/admit-extra", ""])

    assert Path.expand("/tmp/admit-cfg") in roots
    assert Path.expand("/tmp/admit-extra") in roots
    assert Path.join(System.tmp_dir!(), "casein-agent-worktrees") in roots
    assert Path.join("/tmp/admit-home", ".claude") in roots
  end

  test "product sources no longer hard-code a quoted /home/devbox fallback" do
    assert {_, 0} = System.cmd("bash", ["scripts/check-portable-defaults-guard.sh"])
  end

  test "lib does not quote /data/casein-agent-worktrees as a product default" do
    # Same policy as scripts/check-portable-defaults-guard.sh section 3.
    pattern = ~r/["']\/data\/casein-agent-worktrees[^"']*["']/

    hits =
      for path <- Path.wildcard("{lib,config}/**/*.{ex,exs}"),
          File.regular?(path),
          {line, n} <- Enum.with_index(File.stream!(path), 1),
          Regex.match?(pattern, line),
          do: "#{path}:#{n}:#{String.trim(line)}"

    assert hits == []
  end

  defp restore_app(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app(key, value), do: Application.put_env(:casein, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
