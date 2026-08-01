defmodule Scripts.DeployPollerMigrationGuardTest do
  @moduledoc """
  Hermetic coverage of deploy-poller's migration guard.

  Each test creates a local Git remote with fake build and activation scripts;
  no live service, release directory, database, or systemd unit is touched.
  """
  use ExUnit.Case, async: true

  @poller Path.expand("../../scripts/deploy-poller.sh", __DIR__)
  @caddy_lib Path.expand("../../scripts/lib/caddy-upstream.sh", __DIR__)

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "deploy-poller-migrations-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "a revision range without new migrations deploys", %{tmp: tmp} do
    fixture = build_fixture(tmp, :without_migration)

    {output, status} = run_poller(fixture)

    assert status == 0
    assert output =~ "deployed #{String.slice(fixture.target, 0, 7)}"
    refute output =~ "automatic deploy REFUSED"
  end

  test "a revision range that adds a migration is refused before deployment", %{tmp: tmp} do
    fixture = build_fixture(tmp, :with_migration)

    {output, status} = run_poller(fixture)

    assert status != 0
    assert output =~ "automatic deploy REFUSED"
    assert output =~ fixture.migration
    refute File.exists?(fixture.worktree)
  end

  test "the attended migration override allows deployment", %{tmp: tmp} do
    fixture = build_fixture(tmp, :with_migration)

    {output, status} = run_poller(fixture, [{"CASEIN_ALLOW_MIGRATION_DEPLOY", "1"}])

    assert status == 0
    assert output =~ "migration deploy explicitly allowed"
    assert output =~ fixture.migration
    assert output =~ "deployed #{String.slice(fixture.target, 0, 7)}"
  end

  defp build_fixture(tmp, migration_mode) do
    root = Path.join(tmp, "checkout")
    remote = Path.join(tmp, "origin.git")
    worktree = Path.join(tmp, "deploy-build")
    fake_bin = Path.join(tmp, "bin")
    env_file = Path.join(tmp, "casein.env")
    last_deploy_file = Path.join(tmp, "last-deploy.json")

    File.mkdir_p!(Path.join(root, "scripts/lib"))
    File.mkdir_p!(fake_bin)
    File.cp!(@poller, Path.join(root, "scripts/deploy-poller.sh"))
    File.cp!(@caddy_lib, Path.join(root, "scripts/lib/caddy-upstream.sh"))

    write_executable(Path.join(root, "scripts/pre-push-check.sh"), "#!/bin/sh\nexit 0\n")

    write_executable(
      Path.join(root, "scripts/build-release.sh"),
      "#!/bin/sh\nmkdir -p release-out\nprintf built > release-out/artifact\n"
    )

    write_executable(
      Path.join(root, "scripts/deploy-devbox-release.sh"),
      "#!/bin/sh\nexit 0\n"
    )

    write_executable(
      Path.join(root, "scripts/install-agent-shims.sh"),
      "#!/bin/sh\nexit 0\n"
    )

    write_executable(Path.join(fake_bin, "mise"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(root, "app.txt"), "deployed\n")

    git!(root, ["init", "-b", "master"])
    git!(root, ["config", "user.email", "tests@example.com"])
    git!(root, ["config", "user.name", "Casein Tests"])
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "deployed revision"])
    deployed = git!(root, ["rev-parse", "HEAD"])

    File.write!(Path.join(root, "app.txt"), "target\n")

    migration = "priv/repo/migrations/20260801000000_guard_fixture.exs"

    if migration_mode == :with_migration do
      migration_path = Path.join(root, migration)
      File.mkdir_p!(Path.dirname(migration_path))
      File.write!(migration_path, "defmodule GuardFixtureMigration do\nend\n")
    end

    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "target revision"])
    target = git!(root, ["rev-parse", "HEAD"])

    git!(tmp, ["init", "--bare", remote])
    git!(root, ["remote", "add", "origin", remote])
    git!(root, ["push", "-u", "origin", "master"])
    File.write!(env_file, "CASEIN_GIT_REVISION=#{deployed}\n")

    %{
      root: root,
      deployed: deployed,
      target: target,
      migration: migration,
      worktree: worktree,
      fake_bin: fake_bin,
      env_file: env_file,
      last_deploy_file: last_deploy_file,
      deploy_root: Path.join(tmp, "deploy-root"),
      cache_root: Path.join(tmp, "cache"),
      lock: Path.join(tmp, "poller.lock"),
      socket: Path.join(tmp, "current.sock")
    }
  end

  defp run_poller(fixture, extra_env \\ []) do
    env = [
      {"PATH", "#{fixture.fake_bin}:#{System.get_env("PATH")}"},
      {"CASEIN_POLLER_SELFUPDATED", "1"},
      {"CASEIN_POLLER_CADDY_LIB", Path.join(fixture.root, "scripts/lib/caddy-upstream.sh")},
      {"CASEIN_ENV_FILE", fixture.env_file},
      {"CASEIN_DEPLOY_ROOT", fixture.deploy_root},
      {"CASEIN_DEPLOY_WORKTREE", fixture.worktree},
      {"CASEIN_DEPLOY_CACHE_ROOT", fixture.cache_root},
      {"CASEIN_DEPLOY_LOCK", fixture.lock},
      {"CASEIN_CURRENT_SOCK", fixture.socket},
      {"CASEIN_LAST_DEPLOY_FILE", fixture.last_deploy_file}
    ]

    System.cmd("bash", [Path.join(fixture.root, "scripts/deploy-poller.sh")],
      env: env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", args, cd: directory, stderr_to_stdout: true)
    String.trim(output)
  end
end
