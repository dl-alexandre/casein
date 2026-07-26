defmodule Casein.Runtimes.WorktreeReconcilerTest do
  use Casein.TestCase, async: false

  alias Casein.Runtimes
  alias Casein.Runtimes.WorktreeReconciler
  alias Casein.Workspace
  alias Casein.Workspaces.DbIsolation
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Runtimes.clear()
    WorktreeReconciler.clear()

    prev_reconcile_ttl = Application.get_env(:casein, :worktree_reconcile_ttl_ms)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      WorktreeReconciler.clear()
      restore_env(:worktree_reconcile_ttl_ms, prev_reconcile_ttl)
    end)

    :ok
  end

  # ---- reconcile/2 guards ----

  test "reconcile/2 rejects non-binary workspace ids" do
    assert WorktreeReconciler.reconcile(nil) == {:error, :invalid_workspace_id}
    assert WorktreeReconciler.reconcile(123) == {:error, :invalid_workspace_id}
    assert WorktreeReconciler.reconcile(:atom) == {:error, :invalid_workspace_id}
    assert WorktreeReconciler.reconcile(%{}) == {:error, :invalid_workspace_id}
  end

  # ---- reconcile/2 cache freshness ----

  test "reconcile/2 returns the same cached status while TTL is fresh without rediscovering" do
    ws = unique_ws("cache-fresh")
    root = tmp_repo!("cache-fresh")
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    git!(root, ["worktree", "add", "-b", "first-branch", first, "main"])
    seed_workspace(ws, root)

    Application.put_env(:casein, :worktree_reconcile_ttl_ms, 60_000)

    assert {:ok, status1} = WorktreeReconciler.reconcile(ws)
    assert status1.status == :ok
    assert status1.workspace_id == ws
    assert status1.observed_count == 1
    assert status1.expired_count == 0
    assert status1.rejected_count == 0
    assert status1.error == nil
    assert %DateTime{} = status1.reconciled_at
    assert is_integer(status1.monotonic_at)

    # New linked worktree exists on disk/git, but a fresh cache must not re-discover.
    git!(root, ["worktree", "add", "-b", "second-branch", second, "main"])

    assert {:ok, status2} = WorktreeReconciler.reconcile(ws, force: false)
    assert status2 == status1
    assert status2.observed_count == 1
    assert status2.monotonic_at == status1.monotonic_at
    assert status2.reconciled_at == status1.reconciled_at

    assert [%{path: ^first}] = WorktreeReconciler.list_agent_worktrees(ws)
  end

  test "reconcile/2 force:true bypasses a fresh cache and rediscovers" do
    ws = unique_ws("cache-force")
    root = tmp_repo!("cache-force")
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    git!(root, ["worktree", "add", "-b", "force-first", first, "main"])
    seed_workspace(ws, root)

    Application.put_env(:casein, :worktree_reconcile_ttl_ms, 60_000)

    assert {:ok, status1} = WorktreeReconciler.reconcile(ws)
    assert status1.observed_count == 1

    git!(root, ["worktree", "add", "-b", "force-second", second, "main"])

    # Still cached with force:false.
    assert {:ok, %{observed_count: 1, monotonic_at: mono1}} =
             WorktreeReconciler.reconcile(ws, force: false)

    assert mono1 == status1.monotonic_at

    assert {:ok, status_forced} = WorktreeReconciler.reconcile(ws, force: true)
    assert status_forced.status == :ok
    assert status_forced.observed_count == 2
    assert status_forced.expired_count == 0
    assert status_forced.rejected_count == 0
    assert status_forced.monotonic_at != status1.monotonic_at
    assert status_forced.reconciled_at != status1.reconciled_at

    paths =
      ws
      |> WorktreeReconciler.list_agent_worktrees()
      |> Enum.map(& &1.path)
      |> Enum.sort()

    assert paths == Enum.sort([first, second])
  end

  test "reconcile/2 re-discovers when the TTL has expired" do
    ws = unique_ws("cache-stale")
    root = tmp_repo!("cache-stale")
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    git!(root, ["worktree", "add", "-b", "stale-first", first, "main"])
    seed_workspace(ws, root)

    Application.put_env(:casein, :worktree_reconcile_ttl_ms, 60_000)

    assert {:ok, status1} = WorktreeReconciler.reconcile(ws)
    assert status1.observed_count == 1

    git!(root, ["worktree", "add", "-b", "stale-second", second, "main"])

    # Explicit stale TTL via opts (and env) forces rediscovery even without force:true.
    Application.put_env(:casein, :worktree_reconcile_ttl_ms, 0)

    assert {:ok, status_stale} = WorktreeReconciler.reconcile(ws, force: false, ttl_ms: 0)
    assert status_stale.status == :ok
    assert status_stale.observed_count == 2
    assert status_stale.monotonic_at != status1.monotonic_at

    paths =
      ws
      |> Runtimes.list_agent_worktrees()
      |> Enum.map(& &1.path)
      |> Enum.sort()

    assert paths == Enum.sort([first, second])
  end

  # ---- do_reconcile ok / error outcomes ----

  test "reconcile/2 ok path reports observed, expired, and rejected counts from discovery" do
    ws = unique_ws("counts")
    root = tmp_repo!("counts")
    keep = Path.join(root, "keep")
    expire = Path.join(root, "expire-me")
    reject = Path.join(root, "reject-me")

    git!(root, ["worktree", "add", "-b", "keep-branch", keep, "main"])
    git!(root, ["worktree", "add", "-b", "expire-branch", expire, "main"])
    git!(root, ["worktree", "add", "-b", "reject-branch", reject, "main"])
    seed_workspace(ws, root)

    assert {:ok, initial} = WorktreeReconciler.reconcile(ws, force: true)
    assert initial.status == :ok
    assert initial.observed_count == 3
    assert initial.expired_count == 0
    assert initial.rejected_count == 0
    assert initial.error == nil

    # Expire: fully remove from git list + disk.
    git!(root, ["worktree", "remove", "--force", expire])

    # Reject: still listed by git worktree list, but directory is gone.
    File.rm_rf!(reject)

    assert {:ok, status} = WorktreeReconciler.reconcile(ws, force: true)
    assert status.status == :ok
    assert status.workspace_id == ws
    assert status.observed_count == 1
    assert status.expired_count == 1
    assert status.rejected_count == 1
    assert status.error == nil

    payload_paths =
      ws
      |> WorktreeReconciler.list_agent_worktrees()
      |> Enum.map(& &1.path)

    # Surviving worktree is still listed; fully expired path is not.
    assert keep in payload_paths
    refute expire in payload_paths
    assert {:ok, ^status} = WorktreeReconciler.status(ws)
  end

  test "reconcile/2 error path returns {:error, reason} and caches status.status == :error" do
    ws = unique_ws("discover-error")
    root = tmp_repo!("discover-error")
    seed_workspace(ws, root)

    # Force discover_worktrees/1's git_worktree_entries/1 failure branch while
    # git_checkout_root?/1 still succeeds: a PATH-first git shim fails only on
    # `worktree list` and otherwise execs the real binary. Restored in `after`
    # so the window is limited to this reconcile call.
    real_git = System.find_executable("git") || "/usr/bin/git"
    shim_dir = tmp_dir!("git-shim")
    shim = Path.join(shim_dir, "git")

    File.write!(shim, """
    #!/bin/sh
    saw_worktree=0
    for arg in "$@"; do
      if [ "$arg" = "worktree" ]; then
        saw_worktree=1
      fi
      if [ "$arg" = "list" ] && [ "$saw_worktree" = "1" ]; then
        echo "forced worktree list failure" >&2
        exit 128
      fi
    done
    exec "#{real_git}" "$@"
    """)

    File.chmod!(shim, 0o755)

    old_path = System.get_env("PATH") || ""
    System.put_env("PATH", shim_dir <> ":" <> old_path)

    try do
      assert {:error, reason} = WorktreeReconciler.reconcile(ws, force: true)
      assert {:git_worktree_list_failed, 128, output} = reason
      assert output =~ "forced worktree list failure"

      assert {:ok, cached} = WorktreeReconciler.status(ws)
      assert cached.status == :error
      assert cached.error == reason
      assert cached.workspace_id == ws
      assert cached.observed_count == 0
      assert cached.expired_count == 0
      assert cached.rejected_count == 0
    after
      if old_path == "" do
        System.delete_env("PATH")
      else
        System.put_env("PATH", old_path)
      end
    end
  end

  # ---- refresh_agent_worktrees/1 ----

  test "refresh_agent_worktrees/1 forces reconcile then returns active payloads" do
    ws = unique_ws("refresh")
    root = tmp_repo!("refresh")
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    git!(root, ["worktree", "add", "-b", "refresh-first", first, "main"])
    seed_workspace(ws, root)

    Application.put_env(:casein, :worktree_reconcile_ttl_ms, 60_000)

    assert {:ok, %{observed_count: 1}} = WorktreeReconciler.reconcile(ws)

    git!(root, ["worktree", "add", "-b", "refresh-second", second, "main"])

    # force:false would still see only the first; refresh forces rediscovery.
    payloads = WorktreeReconciler.refresh_agent_worktrees(ws)
    paths = payloads |> Enum.map(& &1.path) |> Enum.sort()
    assert paths == Enum.sort([first, second])
    assert length(payloads) == 2

    assert {:ok, %{observed_count: 2, status: :ok}} = WorktreeReconciler.status(ws)
  end

  test "refresh_agent_worktrees/1 returns [] for non-binary workspace ids" do
    assert WorktreeReconciler.refresh_agent_worktrees(nil) == []
    assert WorktreeReconciler.refresh_agent_worktrees(123) == []
    assert WorktreeReconciler.refresh_agent_worktrees(:ws) == []
  end

  # ---- list_agent_worktrees/2 ----

  test "list_agent_worktrees/2 reconciles then returns payloads for binary workspace ids" do
    ws = unique_ws("list")
    root = tmp_repo!("list")
    worktree = Path.join(root, "agent-listed")
    git!(root, ["worktree", "add", "-b", "list-branch", worktree, "main"])
    seed_workspace(ws, root)

    assert :error = WorktreeReconciler.status(ws)

    assert [%{path: ^worktree, source: "git_discovery"}] =
             WorktreeReconciler.list_agent_worktrees(ws)

    assert {:ok, %{status: :ok, observed_count: 1}} = WorktreeReconciler.status(ws)
  end

  test "list_agent_worktrees/2 returns [] for non-binary workspace ids" do
    assert WorktreeReconciler.list_agent_worktrees(nil) == []
    assert WorktreeReconciler.list_agent_worktrees(123, force: true) == []
    assert WorktreeReconciler.list_agent_worktrees(%{}, []) == []
  end

  # ---- status/1 and clear/0 ----

  test "status/1 is :error before reconcile and for non-binary ids, {:ok, cached} after" do
    ws = unique_ws("status")
    root = tmp_repo!("status")
    worktree = Path.join(root, "status-wt")
    git!(root, ["worktree", "add", "-b", "status-branch", worktree, "main"])
    seed_workspace(ws, root)

    assert WorktreeReconciler.status(ws) == :error
    assert WorktreeReconciler.status(nil) == :error
    assert WorktreeReconciler.status(99) == :error

    assert {:ok, reconciled} = WorktreeReconciler.reconcile(ws)
    assert {:ok, cached} = WorktreeReconciler.status(ws)
    assert cached == reconciled
    assert cached.status == :ok
    assert cached.observed_count == 1
    assert cached.workspace_id == ws
  end

  test "clear/0 empties the persistent_term cache so status/1 becomes :error" do
    ws = unique_ws("clear")
    root = tmp_repo!("clear")
    worktree = Path.join(root, "clear-wt")
    git!(root, ["worktree", "add", "-b", "clear-branch", worktree, "main"])
    seed_workspace(ws, root)

    assert {:ok, status} = WorktreeReconciler.reconcile(ws)
    assert {:ok, ^status} = WorktreeReconciler.status(ws)

    assert WorktreeReconciler.clear() == :ok
    assert WorktreeReconciler.status(ws) == :error

    # Other workspaces that were cached are also gone.
    other = unique_ws("clear-other")
    seed_workspace(other, root)
    assert {:ok, _} = WorktreeReconciler.reconcile(other)
    assert {:ok, _} = WorktreeReconciler.status(other)
    assert WorktreeReconciler.clear() == :ok
    assert WorktreeReconciler.status(other) == :error
  end

  # ---- helpers (same seams as runtimes_test / worktree_alarm_test) ----

  defp unique_ws(label) do
    "ws-reconciler-#{label}-#{System.unique_integer([:positive])}"
  end

  defp seed_workspace(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "reconciler",
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => id, "repo" => "casein", "branch" => "main"}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, value), do: Application.put_env(:casein, key, value)

  defp tmp_repo!(name) do
    path = tmp_dir!(name)
    init_repo!(path)
    path
  end

  defp init_repo!(path) do
    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(path, "README.md"), "# Test\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "init"])
    :ok
  end

  defp tmp_dir!(name) do
    root = System.get_env("CASEIN_TEST_TMPDIR") || System.tmp_dir!()
    path = Path.join(root, "casein-reconciler-#{System.unique_integer([:positive])}-#{name}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end
end
