defmodule DevIDE.Deployment.RegistryTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Deployment.Registry

  setup do
    prev_dir = Application.get_env(:dev_ide, :deployment_instance_dir)
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

  defp isolated_instance_dir! do
    dir = Path.join(System.tmp_dir!(), "devide-instances-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:dev_ide, :deployment_instance_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp restore_instance_dir(nil), do: Application.delete_env(:dev_ide, :deployment_instance_dir)
  defp restore_instance_dir(dir), do: Application.put_env(:dev_ide, :deployment_instance_dir, dir)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
