defmodule DevIDE.Files.WatcherTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Files.Watcher

  setup do
    root = Path.join(System.tmp_dir!(), "fw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "README.md"), "hi\n")
    File.write!(Path.join([root, ".git", "HEAD"]), "ref: refs/heads/main\n")
    File.write!(Path.join([root, "_build", "x"]), "noise\n")

    ws_id = "ws-files-watch-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = Watcher.unwatch(ws_id)
      File.rm_rf!(root)
    end)

    {:ok, root: root, ws_id: ws_id}
  end

  test "watch starts a process; unwatch of last consumer stops it", %{root: root, ws_id: ws_id} do
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20)
    assert {:ok, pid} = Watcher.whereis(ws_id)
    assert Process.alive?(pid)

    assert :ok = Watcher.unwatch(ws_id)
    refute Process.alive?(pid)
    assert :error = Watcher.whereis(ws_id)
  end

  test "debounces and broadcasts non-ignored relative paths", %{root: root, ws_id: ws_id} do
    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, Watcher.topic(ws_id))
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 30)

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
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20)

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
        :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20)
        send(parent, :task_ready)
        receive do: (:stop -> :ok)
        :ok = Watcher.unwatch(ws_id)
      end)

    assert_receive :task_ready, 500
    assert :ok = Watcher.watch(ws_id, root, backend: :test, debounce_ms: 20)
    assert {:ok, pid} = Watcher.whereis(ws_id)

    # Parent leaves first — still one consumer.
    assert :ok = Watcher.unwatch(ws_id)
    assert Process.alive?(pid)

    send(task.pid, :stop)
    Task.await(task)
    refute Process.alive?(pid)
  end
end
