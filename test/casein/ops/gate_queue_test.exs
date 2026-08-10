defmodule Casein.Ops.GateQueueTest do
  use ExUnit.Case, async: true

  alias Casein.Ops.GateQueue

  describe "unknown/0 and summary/1 kind discipline" do
    test "unknown is never free or busy" do
      u = GateQueue.unknown()
      assert u.lock_state == :unknown
      refute GateQueue.busy?(u)
      assert GateQueue.summary(u) == "gate unknown"
    end

    test "free summary" do
      snap = %{lock_state: :free, holder: nil, waiter_count: 0, depth: 0}
      assert GateQueue.summary(snap) == "gate free"
      refute GateQueue.busy?(snap)
    end

    test "held summary prefers PR number" do
      snap = %{
        lock_state: :held,
        holder: %{pr: 806, branch: "x", held_for_seconds: 125},
        waiter_count: 2
      }

      assert GateQueue.summary(snap) == "gate held by PR #806 · 2m · 2 waiting"
      assert GateQueue.busy?(snap)
    end

    test "held without PR falls back to branch then pid" do
      assert GateQueue.summary(%{
               lock_state: :held,
               holder: %{pr: nil, branch: "agent/x", held_for_seconds: 5, pid: 1},
               waiter_count: 0
             }) == "gate held by agent/x · 5s"

      assert GateQueue.summary(%{
               lock_state: :held,
               holder: %{pr: nil, branch: nil, pid: 99, held_for_seconds: nil},
               waiter_count: 0
             }) == "gate held by pid 99"
    end
  end

  describe "observe/1 against a fixture proc tree" do
    setup do
      root = Path.join(System.tmp_dir!(), "gate-queue-test-#{System.unique_integer([:positive])}")
      proc = Path.join(root, "proc")
      File.mkdir_p!(proc)
      on_exit(fn -> File.rm_rf(root) end)
      %{root: root, proc: proc}
    end

    test "missing lock path is free", %{proc: proc, root: root} do
      lock = Path.join(root, "missing.lock")
      write_proc_stat(proc, btime: 1_700_000_000)

      assert {:ok, snap} =
               GateQueue.observe(
                 lock_path: lock,
                 proc_root: proc,
                 cache: false
               )

      assert snap.lock_state == :free
      assert snap.depth == 0
      assert snap.holder == nil
    end

    test "held lock with Actions env yields PR holder", %{proc: proc, root: root} do
      lock = Path.join(root, "casein-pr-gate.lock")
      File.write!(lock, "")
      %{major_device: maj, minor_device: min, inode: ino} = File.stat!(lock)

      write_proc_stat(proc, btime: 1_700_000_000)
      write_locks(proc, maj, min, ino, holder_pid: 4242)

      write_pid(proc, 4242,
        cmdline: "bash scripts/pre-push-check.sh",
        environ: %{
          "GITHUB_RUN_ID" => "31342726258",
          "GITHUB_REF" => "refs/pull/806/merge",
          "GITHUB_HEAD_REF" => "agent/opencode/demo",
          "GITHUB_SHA" => "c9ea09e0065e0bf80f327c91d6771643e2ac160b",
          "GITHUB_WORKFLOW" => "PR gate"
        },
        open_lock: lock,
        start_ticks: 100
      )

      # child of same run — not a waiter
      write_pid(proc, 4243,
        cmdline: "mix precommit.ci",
        environ: %{
          "GITHUB_RUN_ID" => "31342726258",
          "GITHUB_REF" => "refs/pull/806/merge"
        },
        open_lock: lock,
        start_ticks: 110
      )

      assert {:ok, snap} =
               GateQueue.observe(
                 lock_path: lock,
                 proc_root: proc,
                 cache: false,
                 now: DateTime.from_unix!(1_700_000_000 + 10)
               )

      assert snap.lock_state == :held
      assert snap.holder.pr == 806
      assert snap.holder.branch == "agent/opencode/demo"
      assert snap.holder.run_id == "31342726258"
      assert snap.holder.sha == "c9ea09e"
      assert snap.waiter_count == 0
      assert snap.depth == 1
      assert GateQueue.summary(snap) =~ "PR #806"
    end

    test "distinct run_id with flock wchan counts as waiter", %{proc: proc, root: root} do
      lock = Path.join(root, "casein-pr-gate.lock")
      File.write!(lock, "")
      %{major_device: maj, minor_device: min, inode: ino} = File.stat!(lock)

      write_proc_stat(proc, btime: 1_700_000_000)
      write_locks(proc, maj, min, ino, holder_pid: 100)

      write_pid(proc, 100,
        cmdline: "bash gate",
        environ: %{
          "GITHUB_RUN_ID" => "111",
          "GITHUB_REF" => "refs/pull/1/merge"
        },
        open_lock: lock
      )

      write_pid(proc, 200,
        cmdline: "bash waiting",
        environ: %{
          "GITHUB_RUN_ID" => "222",
          "GITHUB_REF" => "refs/pull/2/merge"
        },
        open_lock: lock,
        wchan: "flock_lock_inode"
      )

      assert {:ok, snap} =
               GateQueue.observe(lock_path: lock, proc_root: proc, cache: false)

      assert snap.lock_state == :held
      assert snap.holder.pr == 1
      assert snap.waiter_count == 1
      assert hd(snap.waiters).pr == 2
      assert snap.depth == 2
    end

    test "unreadable proc yields error not free", %{root: root} do
      lock = Path.join(root, "x.lock")
      File.write!(lock, "")
      missing_proc = Path.join(root, "no-proc")

      assert {:error, :no_proc} =
               GateQueue.observe(
                 lock_path: lock,
                 proc_root: missing_proc,
                 cache: false
               )
    end
  end

  defp write_proc_stat(proc, btime: btime) do
    File.write!(Path.join(proc, "stat"), "btime #{btime}\n")
  end

  defp write_locks(proc, maj, min, ino, holder_pid: pid) do
    # /proc/locks prints maj:min in hex (often zero-padded minor).
    hex =
      "#{Integer.to_string(maj, 16)}:#{String.pad_leading(Integer.to_string(min, 16), 2, "0")}"

    line = "1: FLOCK  ADVISORY  WRITE #{pid} #{hex}:#{ino} 0 EOF\n"
    File.write!(Path.join(proc, "locks"), line)
  end

  defp write_pid(proc, pid, opts) do
    dir = Path.join(proc, Integer.to_string(pid))
    fd_dir = Path.join(dir, "fd")
    File.mkdir_p!(fd_dir)

    cmdline = Keyword.get(opts, :cmdline, "bash")
    File.write!(Path.join(dir, "cmdline"), String.replace(cmdline, " ", <<0>>) <> <<0>>)

    env =
      opts
      |> Keyword.get(:environ, %{})
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
      |> Enum.join(<<0>>)

    File.write!(Path.join(dir, "environ"), env <> <<0>>)

    if lock = Keyword.get(opts, :open_lock) do
      # Symlink fd → lock path (GateQueue uses File.read_link)
      File.ln_s!(lock, Path.join(fd_dir, "9"))
    end

    if wchan = Keyword.get(opts, :wchan) do
      File.write!(Path.join(dir, "wchan"), wchan)
    else
      File.write!(Path.join(dir, "wchan"), "0")
    end

    # Minimal /proc/pid/stat — field 22 (starttime) after comm.
    # Format: pid (comm) state ppid ... starttime at index 19 of post-comm fields.
    start_ticks = Keyword.get(opts, :start_ticks, 0)
    # 20 fields after state before we need starttime at post-comm index 19:
    # state + 19 more = starttime is the 20th token after ') '
    filler = Enum.map_join(1..19, " ", fn _ -> "0" end)
    # After ') ': state(0) ppid... utime... starttime is field index 19
    # tokens: [state, ppid, pgrp, session, tty, tpgid, flags, minflt, cminflt,
    #  majflt, cmajflt, utime, stime, cutime, cstime, priority, nice,
    #  num_threads, itrealvalue, starttime]
    rest =
      [
        "R",
        "1",
        "1",
        "1",
        "0",
        "-1",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "20",
        "0",
        "1",
        "0",
        Integer.to_string(start_ticks)
      ]
      |> Enum.join(" ")

    _ = filler
    File.write!(Path.join(dir, "stat"), "#{pid} (bash) #{rest}\n")
  end
end
