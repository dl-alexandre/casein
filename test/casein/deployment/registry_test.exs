defmodule Casein.Deployment.RegistryTest do
  use Casein.TestCase, async: false

  alias Casein.Deployment.Registry

  setup do
    prev_dir = Application.get_env(:casein, :deployment_instance_dir)
    on_exit(fn -> restore_instance_dir(prev_dir) end)
    :ok
  end

  test "version prefers DEVIDE_GIT_REVISION when set" do
    prev = System.get_env("DEVIDE_GIT_REVISION")
    System.put_env("DEVIDE_GIT_REVISION", "abc123deadbeef")
    on_exit(fn -> restore_env("DEVIDE_GIT_REVISION", prev) end)

    assert Registry.version() == "abc123deadbeef"
  end

  test "list_instances parses heartbeat json and ignores corrupt files" do
    dir = isolated_instance_dir!()

    valid = %{
      "id" => "inst-1",
      "version" => "sha-test",
      "draining" => false
    }

    File.write!(Path.join(dir, "inst-1.json"), Jason.encode!(valid))
    File.write!(Path.join(dir, "broken.json"), "not-json")
    File.write!(Path.join(dir, "notes.txt"), "skip")

    assert [%{"id" => "inst-1", "version" => "sha-test"}] = Registry.list_instances()
  end

  test "mark_draining flips draining flag in the running instance heartbeat" do
    id = Registry.instance_id()
    assert :ok = Registry.mark_draining()

    instance =
      Registry.list_instances()
      |> Enum.find(&(&1["id"] == id))

    assert instance["draining"] == true
  end

  test "instance_id, http_port, and socket_path are readable" do
    assert is_binary(Registry.instance_id())
    assert is_binary(Registry.http_port())
    assert Registry.socket_path() == nil or is_binary(Registry.socket_path())
  end

  # Devbox terminals inherit DEVIDE_INSTANCE_UUID from the canary that spawned
  # them, so a secondary boot (mix test, release eval) shares the serving
  # instance's identity. Overwriting its heartbeat with our short-lived pid made
  # the deploy's stale-record cleanup delete it, and the instance then never
  # received its drain signal. Liveness is injected (see owner_alive?/1) so this
  # runs the same on macOS dev machines as on the Linux devbox.
  test "init leaves a heartbeat owned by another live Casein process untouched" do
    dir = isolated_instance_dir!()
    put_instance_uuid!("conflict-test")
    stub_owner_liveness!(fn _pid -> true end)

    path = Path.join(dir, "conflict-test.json")
    File.write!(path, Jason.encode!(%{"id" => "conflict-test", "pid" => "424242"}))

    assert {:ok, %{file_path: nil}} = Registry.init([])
    assert %{"pid" => "424242"} = path |> File.read!() |> Jason.decode!()
  end

  test "init overwrites a heartbeat whose owner is not a live Casein process" do
    dir = isolated_instance_dir!()
    put_instance_uuid!("dead-owner-test")
    # False stands in for both "pid is dead" and "pid was recycled by an
    # unrelated process" — the cmdline check rejects the recycled case too.
    stub_owner_liveness!(fn _pid -> false end)

    path = Path.join(dir, "dead-owner-test.json")
    File.write!(path, Jason.encode!(%{"id" => "dead-owner-test", "pid" => "999999999"}))

    assert {:ok, %{file_path: ^path}} = Registry.init([])
    assert %{"pid" => pid} = path |> File.read!() |> Jason.decode!()
    assert pid == System.pid()
  end

  test "init ignores a heartbeat that records our own pid" do
    dir = isolated_instance_dir!()
    put_instance_uuid!("self-pid-test")
    # Liveness would say true, but a record bearing our own pid must never count
    # as a foreign owner — otherwise a re-init over our own file would refuse.
    stub_owner_liveness!(fn _pid -> true end)

    path = Path.join(dir, "self-pid-test.json")
    File.write!(path, Jason.encode!(%{"id" => "self-pid-test", "pid" => System.pid()}))

    assert {:ok, %{file_path: ^path}} = Registry.init([])
  end

  defp isolated_instance_dir! do
    dir = Path.join(System.tmp_dir!(), "devide-instances-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:casein, :deployment_instance_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp restore_instance_dir(nil), do: Application.delete_env(:casein, :deployment_instance_dir)
  defp restore_instance_dir(dir), do: Application.put_env(:casein, :deployment_instance_dir, dir)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp put_instance_uuid!(id) do
    prev = System.get_env("DEVIDE_INSTANCE_UUID")
    System.put_env("DEVIDE_INSTANCE_UUID", id)
    on_exit(fn -> restore_env("DEVIDE_INSTANCE_UUID", prev) end)
  end

  defp stub_owner_liveness!(fun) do
    prev = Application.get_env(:casein, :deployment_owner_liveness)
    Application.put_env(:casein, :deployment_owner_liveness, fun)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:casein, :deployment_owner_liveness)
        _ -> Application.put_env(:casein, :deployment_owner_liveness, prev)
      end
    end)
  end
end
