defmodule Casein.Deployment.DriftTest do
  use Casein.TestCase, async: false

  import Casein.Test.GitRepoCase

  alias Casein.Deployment.Drift

  test "assess returns current when a short deployed SHA matches the remote head" do
    assert Drift.assess("1fb643a", {:ok, "1fb643af2c58da2c9b10019cc3de1b06555e3732"}, "master") ==
             :current
  end

  test "assess flags manual labels as deploy drift" do
    assert {:drift, %{reason: :manual_revision, current: "5b1dd81-terminal-handshake-hotfix"}} =
             Drift.assess(
               "5b1dd81-terminal-handshake-hotfix",
               {:ok, String.duplicate("a", 40)},
               "master"
             )
  end

  test "assess flags SHA mismatches as deploy drift" do
    assert {:drift, %{reason: :revision_differs, current: "1fb643a"}} =
             Drift.assess("1fb643a", {:ok, String.duplicate("b", 40)}, "master")
  end

  test "assess keeps remote lookup failures as unknown" do
    assert {:unknown, %{reason: :remote_lookup_failed}} =
             Drift.assess("1fb643a", {:error, :nxdomain}, "master")
  end

  test "assess treats missing current revision as unknown" do
    remote = String.duplicate("a", 40)

    assert {:unknown, %{reason: :missing_current_revision, remote: ^remote}} =
             Drift.assess(nil, {:ok, remote}, "master")
  end

  test "assess accepts short deployed SHAs that prefix the remote head" do
    remote = "1fb643af2c58da2c9b10019cc3de1b06555e3732"
    assert Drift.assess("1fb643a", {:ok, remote}, "master") == :current
  end

  test "branch reads CASEIN_GIT_BRANCH when set" do
    prev = System.get_env("CASEIN_GIT_BRANCH")
    System.put_env("CASEIN_GIT_BRANCH", "release/test")
    on_exit(fn -> restore_env("CASEIN_GIT_BRANCH", prev) end)

    assert Drift.branch() == "release/test"
  end

  test "remote_head returns cached results within the TTL" do
    branch = "cache-test-#{System.unique_integer([:positive])}"
    sha = String.duplicate("c", 40)
    key = {Drift, :remote_head, branch}

    :persistent_term.put(key, {{:ok, sha}, System.monotonic_time(:millisecond)})

    on_exit(fn -> :persistent_term.erase(key) end)

    assert {:ok, ^sha} = Drift.remote_head(branch: branch, cache_ttl_ms: 60_000)
  end

  test "remote_head is neutral when an operator has not configured a repository" do
    previous_remote = System.get_env("CASEIN_GIT_REMOTE")
    previous_deployment = Application.get_env(:casein, :deployment)

    System.delete_env("CASEIN_GIT_REMOTE")

    Application.put_env(
      :casein,
      :deployment,
      Keyword.delete(previous_deployment || [], :git_remote)
    )

    on_exit(fn ->
      restore_env("CASEIN_GIT_REMOTE", previous_remote)

      if previous_deployment do
        Application.put_env(:casein, :deployment, previous_deployment)
      else
        Application.delete_env(:casein, :deployment)
      end
    end)

    assert {:error, :not_configured} = Drift.remote_head(cache_ttl_ms: 0)
  end

  test "check_async is a no-op when CASEIN_DEPLOY_DRIFT_CHECK disables it" do
    prev = System.get_env("CASEIN_DEPLOY_DRIFT_CHECK")
    System.put_env("CASEIN_DEPLOY_DRIFT_CHECK", "0")
    on_exit(fn -> restore_env("CASEIN_DEPLOY_DRIFT_CHECK", prev) end)

    assert :ok = Drift.check_async()
  end

  test "check_and_broadcast returns current when the running revision matches cached remote" do
    sha = String.duplicate("d", 40)
    branch = "broadcast-#{System.unique_integer([:positive])}"
    key = {Drift, :remote_head, branch}

    :persistent_term.put(key, {{:ok, sha}, System.monotonic_time(:millisecond)})

    prev_rev = System.get_env("DEVIDE_GIT_REVISION")
    prev_branch = System.get_env("CASEIN_GIT_BRANCH")
    System.put_env("DEVIDE_GIT_REVISION", sha)
    System.put_env("CASEIN_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_env("DEVIDE_GIT_REVISION", prev_rev)
      restore_env("CASEIN_GIT_BRANCH", prev_branch)
      :persistent_term.erase(key)
    end)

    assert :current = Drift.check_and_broadcast()
  end

  test "check_and_broadcast returns drift when the running revision is a manual label" do
    remote = String.duplicate("f", 40)
    branch = "drift-#{System.unique_integer([:positive])}"
    key = {Drift, :remote_head, branch}

    :persistent_term.put(key, {{:ok, remote}, System.monotonic_time(:millisecond)})

    prev_rev = System.get_env("DEVIDE_GIT_REVISION")
    prev_branch = System.get_env("CASEIN_GIT_BRANCH")
    System.put_env("DEVIDE_GIT_REVISION", "manual-hotfix-label")
    System.put_env("CASEIN_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_env("DEVIDE_GIT_REVISION", prev_rev)
      restore_env("CASEIN_GIT_BRANCH", prev_branch)
      :persistent_term.erase(key)
    end)

    assert {:drift, %{reason: :manual_revision}} = Drift.check_and_broadcast()
  end

  test "check_and_broadcast with broadcast: false suppresses the deploy_drift fan-out" do
    remote = String.duplicate("e", 40)
    branch = "quiet-#{System.unique_integer([:positive])}"
    key = {Drift, :remote_head, branch}

    :persistent_term.put(key, {{:ok, remote}, System.monotonic_time(:millisecond)})

    prev_rev = System.get_env("DEVIDE_GIT_REVISION")
    prev_branch = System.get_env("CASEIN_GIT_BRANCH")
    System.put_env("DEVIDE_GIT_REVISION", "manual-hotfix-label")
    System.put_env("CASEIN_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_env("DEVIDE_GIT_REVISION", prev_rev)
      restore_env("CASEIN_GIT_BRANCH", prev_branch)
      :persistent_term.erase(key)
    end)

    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "deploy:updates")

    assert {:drift, _info} = Drift.check_and_broadcast(log: false, broadcast: false)
    refute_receive {:deploy_drift, _info}, 100
  end

  test "broadcast_drift fans out only a drifted status" do
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "deploy:updates")

    assert :ok = Drift.broadcast_drift({:drift, %{reason: :revision_differs}})
    assert_receive {:deploy_drift, %{reason: :revision_differs}}

    assert :ok = Drift.broadcast_drift(:current)
    assert :ok = Drift.broadcast_drift(nil)
    refute_receive {:deploy_drift, _info}, 100
  end

  test "assess treats blank current revision as unknown" do
    remote = String.duplicate("a", 40)

    assert {:unknown, %{reason: :missing_current_revision}} =
             Drift.assess("  ", {:ok, remote}, "master")
  end

  test "assess returns current when deployed SHA equals remote head" do
    sha = String.duplicate("9", 40)
    assert :current = Drift.assess(sha, {:ok, sha}, "master")
  end

  test "remote_head fetches SHA via git ls-remote when cache is disabled" do
    tmp = Path.join(tmp_root(), "drift-remote-#{System.unique_integer([:positive])}")
    bare = Path.join(tmp, "bare.git")
    main = Path.join(tmp, "main")
    branch = "drift-main"

    on_exit(fn -> File.rm_rf!(tmp) end)

    File.mkdir_p!(bare)
    File.mkdir_p!(main)
    git!(bare, ["init", "--bare", "--initial-branch=#{branch}"])
    git!(main, ["init", "--initial-branch=#{branch}"])
    git!(main, ["config", "user.name", "Test"])
    git!(main, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(main, "README.md"), "drift\n")
    git!(main, ["add", "README.md"])
    git!(main, ["commit", "-m", "init"])
    git!(main, ["remote", "add", "origin", bare])
    git!(main, ["push", "-u", "origin", branch])

    expected = git!(main, ["rev-parse", "HEAD"])

    prev_remote = System.get_env("CASEIN_GIT_REMOTE")
    prev_branch = System.get_env("CASEIN_GIT_BRANCH")
    System.put_env("CASEIN_GIT_REMOTE", Path.expand(bare))
    System.put_env("CASEIN_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_env("CASEIN_GIT_REMOTE", prev_remote)
      restore_env("CASEIN_GIT_BRANCH", prev_branch)
    end)

    assert {:ok, ^expected} = Drift.remote_head(cache_ttl_ms: 0)
  end

  test "remote_head returns timeout when ls-remote exceeds the configured budget" do
    prev_deploy = Application.get_env(:casein, :deployment)

    Application.put_env(:casein, :deployment,
      git_remote: "https://github.com/dl-alexandre/casein.git",
      git_branch: "master",
      ls_remote_timeout_ms: 1,
      remote_head_cache_ttl_ms: 0
    )

    on_exit(fn ->
      if prev_deploy,
        do: Application.put_env(:casein, :deployment, prev_deploy),
        else: Application.delete_env(:casein, :deployment)
    end)

    assert {:error, :ls_remote_timeout} = Drift.remote_head(cache_ttl_ms: 0)
  end

  test "remote_head refetches when the cached entry is stale" do
    tmp = Path.join(tmp_root(), "drift-stale-#{System.unique_integer([:positive])}")
    bare = Path.join(tmp, "bare.git")
    main = Path.join(tmp, "main")
    branch = "stale-branch"

    on_exit(fn -> File.rm_rf!(tmp) end)

    File.mkdir_p!(bare)
    File.mkdir_p!(main)
    git!(bare, ["init", "--bare", "--initial-branch=#{branch}"])
    git!(main, ["init", "--initial-branch=#{branch}"])
    git!(main, ["config", "user.name", "Test"])
    git!(main, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(main, "README.md"), "stale\n")
    git!(main, ["add", "README.md"])
    git!(main, ["commit", "-m", "init"])
    git!(main, ["remote", "add", "origin", bare])
    git!(main, ["push", "-u", "origin", branch])

    expected = git!(main, ["rev-parse", "HEAD"])
    key = {Drift, :remote_head, branch}
    stale_sha = String.duplicate("0", 40)

    :persistent_term.put(
      key,
      {{:ok, stale_sha}, System.monotonic_time(:millisecond) - 120_000}
    )

    prev_remote = System.get_env("CASEIN_GIT_REMOTE")
    prev_branch = System.get_env("CASEIN_GIT_BRANCH")
    System.put_env("CASEIN_GIT_REMOTE", Path.expand(bare))
    System.put_env("CASEIN_GIT_BRANCH", branch)

    on_exit(fn ->
      restore_env("CASEIN_GIT_REMOTE", prev_remote)
      restore_env("CASEIN_GIT_BRANCH", prev_branch)
      :persistent_term.erase(key)
    end)

    assert {:ok, ^expected} = Drift.remote_head(branch: branch, cache_ttl_ms: 60_000)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
