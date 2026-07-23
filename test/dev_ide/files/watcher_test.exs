defmodule DevIDE.Files.WatcherTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Files.Watcher

  setup do
    root = Path.join(System.tmp_dir!(), "fw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.mkdir_p!(Path.join(root, "node_modules"))
    File.write!(Path.join(root, "README.md"), "hi\n")
    File.write!(Path.join([root, ".git", "HEAD"]), "ref: refs/heads/main\n")
    File.write!(Path.join([root, "_build", "x"]), "noise\n")
    File.write!(Path.join([root, "node_modules", "pkg"]), "noise\n")

    ws_id = "ws-files-watch-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = Watcher.unwatch(ws_id)
      File.rm_rf!(root)
    end)

    {:ok, root: root, ws_id: ws_id}
  end

  test "watch starts a process; unwatch of last consumer stops it after linger", %{
    root: root,
    ws_id: ws_id
  } do
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20, linger_ms: 30)
    assert {:ok, pid} = Watcher.whereis(ws_id)
    assert Process.alive?(pid)

    ref = Process.monitor(pid)
    assert :ok = Watcher.unwatch(ws_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    # Registry cleanup after the DOWN is itself async; poll until gone.
    wait_until(fn -> Watcher.whereis(ws_id) == :error end)
  end

  test "debounces and broadcasts non-ignored relative paths", %{root: root, ws_id: ws_id} do
    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 30, linger_ms: 50)

    abs_readme = Path.join(root, "README.md")
    abs_lib = Path.join([root, "lib", "a.ex"])
    abs_git = Path.join([root, ".git", "HEAD"])
    abs_build = Path.join([root, "_build", "x"])

    :ok = Watcher.notify(ws_id, abs_readme)
    :ok = Watcher.notify(ws_id, abs_lib)
    :ok = Watcher.notify(ws_id, abs_git)
    :ok = Watcher.notify(ws_id, abs_build)

    assert_receive {:files_changed, ^ws_id, %{paths: paths}}, 500
    assert "README.md" in paths
    assert Path.join("lib", "a.ex") in paths or "lib/a.ex" in paths
    refute Enum.any?(paths, &String.starts_with?(&1, ".git"))
    refute Enum.any?(paths, &String.starts_with?(&1, "_build"))

    # Coalesced — one flush for the burst.
    refute_receive {:files_changed, ^ws_id, _}, 80
  end

  test "drops events outside the workspace root", %{root: root, ws_id: ws_id} do
    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20, linger_ms: 50)

    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "x")
    on_exit(fn -> File.rm(outside) end)

    :ok = Watcher.notify(ws_id, outside)
    refute_receive {:files_changed, ^ws_id, _}, 100
  end

  test "second concurrent watcher keeps process alive until both leave", %{
    root: root,
    ws_id: ws_id
  } do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20, linger_ms: 30)
        send(parent, :task_ready)
        receive do: (:stop -> :ok)
        :ok = Watcher.unwatch(ws_id)
      end)

    assert_receive :task_ready, 500
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20, linger_ms: 30)
    assert {:ok, pid} = Watcher.whereis(ws_id)

    # Parent leaves first — still one consumer.
    assert :ok = Watcher.unwatch(ws_id)
    assert Process.alive?(pid)

    send(task.pid, :stop)
    Task.await(task)
    # Linger may keep the process briefly; wait for stop.
    ref = Process.monitor(pid)

    if Process.alive?(pid) do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end
  end

  test "watched_dirs excludes ignored top-level dirs and keeps root non-recursive", %{
    root: root,
    ws_id: ws_id
  } do
    computed = Watcher.compute_watched_dirs(root)
    lib = Path.expand(Path.join(root, "lib"))
    assert computed.recursive == [lib]
    assert computed.non_recursive == [Path.expand(root)]

    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20, linger_ms: 50)
    assert {:ok, pid} = Watcher.whereis(ws_id)
    state = :sys.get_state(pid)
    assert state.watched_dirs.recursive == [lib]
    assert state.watched_dirs.non_recursive == [Path.expand(root)]
    refute Enum.any?(state.watched_dirs.recursive, &String.contains?(&1, ".git"))
    refute Enum.any?(state.watched_dirs.recursive, &String.contains?(&1, "_build"))
    refute Enum.any?(state.watched_dirs.recursive, &String.contains?(&1, "node_modules"))
  end

  test "root-level file change is in scope (native or dirs computation)", %{
    root: root,
    ws_id: ws_id
  } do
    if System.find_executable("inotifywait") do
      :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
      assert :ok = Watcher.watch(ws_id, root, backend: :native, debounce_ms: 40, linger_ms: 200)

      file = Path.join(root, "file.txt")

      # Retry write until native inotify is ready and the debounced event arrives.
      paths =
        wait_until_files_changed(
          ws_id,
          fn paths -> "file.txt" in paths end,
          fn -> File.write!(file, "hello\n") end,
          2_000
        )

      assert "file.txt" in paths
    else
      computed = Watcher.compute_watched_dirs(root)
      assert Path.expand(root) in computed.non_recursive
    end
  end

  test "new top-level dir then nested file is eventually observed (native or rescan flag)", %{
    root: root,
    ws_id: ws_id
  } do
    if System.find_executable("inotifywait") do
      :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
      assert :ok = Watcher.watch(ws_id, root, backend: :native, debounce_ms: 40, linger_ms: 500)

      # Warm native watcher: root non-recursive inotify is ready once a root
      # file write is observed (mkdir is single-shot — cannot retry).
      probe = Path.join(root, ".fw_probe")

      _ =
        wait_until_files_changed(
          ws_id,
          fn paths -> ".fw_probe" in paths end,
          fn -> File.write!(probe, "probe\n") end,
          2_000
        )

      _ = File.rm(probe)
      drain_files_changed(ws_id)

      new_dir = Path.join(root, "src")
      File.mkdir_p!(new_dir)

      # Wait for root non-recursive event → needs_rescan → restart to include src.
      wait_until(
        fn ->
          case Watcher.whereis(ws_id) do
            {:ok, pid} ->
              state = :sys.get_state(pid)
              Enum.any?(state.watched_dirs.recursive, &String.ends_with?(&1, "/src"))

            :error ->
              false
          end
        end,
        3_000
      )

      # Drain broadcasts from the directory create / rescan cycle.
      drain_files_changed(ws_id)

      nested = Path.join(new_dir, "app.ex")

      # Retry write until restarted inotifywait recursive walk is ready.
      paths =
        wait_until_files_changed(
          ws_id,
          fn paths ->
            Enum.any?(paths, fn p ->
              p == "src/app.ex" or String.ends_with?(p, "app.ex")
            end)
          end,
          fn -> File.write!(nested, "defmodule App do\nend\n") end,
          3_000
        )

      assert Enum.any?(paths, fn p ->
               p == "src/app.ex" or String.ends_with?(p, "app.ex")
             end)
    else
      # Without inotifywait, verify rescan marking via notify injection.
      :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
      assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 30, linger_ms: 50)
      assert {:ok, pid} = Watcher.whereis(ws_id)

      new_dir = Path.join(root, "src")
      File.mkdir_p!(new_dir)
      :ok = Watcher.notify(ws_id, new_dir)
      # Wait for flush to process needs_rescan (path list, then post-restart :all).
      assert_receive {:files_changed, ^ws_id, _}, 500
      assert_receive {:files_changed, ^ws_id, %{paths: :all}}, 500
      state = :sys.get_state(pid)
      assert state.needs_rescan == false
      assert Enum.any?(state.watched_dirs.recursive, &String.ends_with?(&1, "/src"))
    end
  end

  test "unwatch then watch within linger keeps same fs_pids; linger stops without rewatch", %{
    root: root,
    ws_id: ws_id
  } do
    backend =
      if System.find_executable("inotifywait") do
        :native
      else
        :test
      end

    assert :ok = Watcher.watch(ws_id, root, backend: backend, debounce_ms: 20, linger_ms: 200)
    assert {:ok, pid} = Watcher.whereis(ws_id)
    state1 = :sys.get_state(pid)
    fs_pids1 = state1.fs_pids

    assert :ok = Watcher.unwatch(ws_id)
    # Still alive during linger.
    assert Process.alive?(pid)

    assert :ok = Watcher.watch(ws_id, root, backend: backend, debounce_ms: 20, linger_ms: 200)
    assert {:ok, ^pid} = Watcher.whereis(ws_id)
    state2 = :sys.get_state(pid)
    assert state2.fs_pids == fs_pids1

    # Now leave for good with a short linger and wait for stop.
    assert :ok = Watcher.unwatch(ws_id)
    # Force a fresh watcher with short linger for the stop assertion.
    ws_id2 = ws_id <> "-linger-stop"
    assert :ok = Watcher.watch(ws_id2, root, backend: :test, debounce_ms: 20, linger_ms: 50)
    assert {:ok, pid2} = Watcher.whereis(ws_id2)
    ref = Process.monitor(pid2)
    assert :ok = Watcher.unwatch(ws_id2)
    assert_receive {:DOWN, ^ref, :process, ^pid2, _}, 1_000
  end

  test "watch/2 concurrent-stop race never exits the caller", %{root: root, ws_id: ws_id} do
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20, linger_ms: 10)

    for _ <- 1..30 do
      case Watcher.whereis(ws_id) do
        {:ok, p} -> Process.exit(p, :kill)
        :error -> :ok
      end

      result = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20, linger_ms: 10)
      assert result in [:ok, {:error, :watcher_unavailable}]
    end
  end

  test "event on already-watched top-level dir does not rescan; new dir does", %{
    root: root,
    ws_id: ws_id
  } do
    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 30, linger_ms: 50)
    assert {:ok, pid} = Watcher.whereis(ws_id)

    lib = Path.join(root, "lib")
    watched_before = :sys.get_state(pid).watched_dirs

    # Existing recursive dir — chmod/utimes-style noise must not restart backends.
    :ok = Watcher.notify(ws_id, lib)

    assert_receive {:files_changed, ^ws_id, %{paths: paths}}, 500
    assert "lib" in paths
    refute_receive {:files_changed, ^ws_id, %{paths: :all}}, 80

    state = :sys.get_state(pid)
    assert state.needs_rescan == false
    assert state.watched_dirs == watched_before

    # Genuinely new top-level dir still triggers rescan + :all resync broadcast.
    new_dir = Path.join(root, "src")
    File.mkdir_p!(new_dir)
    :ok = Watcher.notify(ws_id, new_dir)

    assert_receive {:files_changed, ^ws_id, %{paths: new_paths}}, 500
    assert "src" in new_paths
    assert_receive {:files_changed, ^ws_id, %{paths: :all}}, 500

    state = :sys.get_state(pid)
    assert state.needs_rescan == false
    assert Enum.any?(state.watched_dirs.recursive, &String.ends_with?(&1, "/src"))
  end

  test "rescan restart broadcasts %{paths: :all} after backends restart", %{
    root: root,
    ws_id: ws_id
  } do
    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 30, linger_ms: 50)

    new_dir = Path.join(root, "apps")
    File.mkdir_p!(new_dir)
    :ok = Watcher.notify(ws_id, new_dir)

    # First the pending path list, then the post-restart full refresh.
    assert_receive {:files_changed, ^ws_id, %{paths: paths}}, 500
    assert "apps" in paths
    assert_receive {:files_changed, ^ws_id, %{paths: :all}}, 500
    refute_receive {:files_changed, ^ws_id, _}, 80
  end

  test "pending overflow collapses to a single %{paths: :all} broadcast", %{
    root: root,
    ws_id: ws_id
  } do
    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 40, linger_ms: 50)

    # More than @max_pending_paths (500) distinct relative paths in one window.
    for i <- 1..501 do
      :ok = Watcher.notify(ws_id, Path.join(root, "f-#{i}.txt"))
    end

    assert_receive {:files_changed, ^ws_id, %{paths: :all}}, 500
    refute_receive {:files_changed, ^ws_id, _}, 80
  end

  # -- helpers --------------------------------------------------------------

  # Poll `fun` until truthy or `timeout` ms, then flunk. Backoff is a short
  # mailbox wait — not Process.sleep — so the poll stays cooperative.
  defp wait_until(fun, timeout \\ 2_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout)
  end

  defp do_wait_until(fun, deadline, timeout) do
    case fun.() do
      result when result not in [false, nil] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("wait_until timed out after #{timeout}ms")
        else
          receive do
          after
            15 -> :ok
          end

          do_wait_until(fun, deadline, timeout)
        end
    end
  end

  # Retry a side-effect (write/touch) until a matching {:files_changed} arrives.
  # Uses only `receive after` for timing so messages are not stolen by a
  # separate poller backoff, and converges as soon as native inotify is ready.
  defp wait_until_files_changed(ws_id, path_pred, write_fun, timeout)
       when is_function(path_pred, 1) and is_function(write_fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_files_changed(ws_id, path_pred, write_fun, deadline, timeout)
  end

  defp do_wait_until_files_changed(ws_id, path_pred, write_fun, deadline, timeout) do
    write_fun.()

    receive do
      {:files_changed, ^ws_id, %{paths: paths}} ->
        if path_pred.(paths) do
          paths
        else
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("wait_until_files_changed timed out after #{timeout}ms")
          else
            do_wait_until_files_changed(ws_id, path_pred, write_fun, deadline, timeout)
          end
        end
    after
      50 ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("wait_until_files_changed timed out after #{timeout}ms")
        else
          do_wait_until_files_changed(ws_id, path_pred, write_fun, deadline, timeout)
        end
    end
  end

  defp drain_files_changed(ws_id) do
    Enum.reduce_while(1..5, :ok, fn _, acc ->
      receive do
        {:files_changed, ^ws_id, _} -> {:cont, acc}
      after
        100 -> {:halt, acc}
      end
    end)
  end
end
