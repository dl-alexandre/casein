defmodule Casein.Previews.EnvRegistryTest do
  use Casein.TestCase, async: false

  alias Casein.Previews.EnvRegistry

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "casein-env-registry-#{System.unique_integer([:positive])}"
      )

    inst_dir = Path.join(home, "instances")
    File.mkdir_p!(inst_dir)

    prev_home = Application.get_env(:casein, :preview_env_home)
    prev_env = System.get_env("CASEIN_PREVIEW_HOME")
    System.delete_env("CASEIN_PREVIEW_HOME")
    Application.put_env(:casein, :preview_env_home, home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_preview_home(prev_home)

      if prev_env,
        do: System.put_env("CASEIN_PREVIEW_HOME", prev_env),
        else: System.delete_env("CASEIN_PREVIEW_HOME")
    end)

    %{home: home, inst_dir: inst_dir}
  end

  test "list_instances returns decoded JSON maps sorted newest first", %{inst_dir: inst_dir} do
    write_instance!(inst_dir, "older.json", %{
      "id" => "prev-old",
      "status" => "running",
      "started_at" => "2026-06-18T10:00:00Z"
    })

    write_instance!(inst_dir, "newer.json", %{
      "id" => "prev-new",
      "status" => "running",
      "started_at" => "2026-06-18T12:00:00Z"
    })

    assert [%{"id" => "prev-new"}, %{"id" => "prev-old"}] = EnvRegistry.list_instances()
  end

  test "running_instances filters by status running", %{inst_dir: inst_dir} do
    write_instance!(inst_dir, "running.json", %{"id" => "up", "status" => "running"})
    write_instance!(inst_dir, "dead.json", %{"id" => "down", "status" => "failed"})

    ids = EnvRegistry.running_instances() |> Enum.map(& &1["id"])
    assert "up" in ids
    refute "down" in ids
  end

  test "get/1 fetches a single instance by id", %{inst_dir: inst_dir} do
    write_instance!(inst_dir, "prev-abc.json", %{"id" => "prev-abc", "port" => "41042"})

    assert %{"id" => "prev-abc"} = EnvRegistry.get("prev-abc")
    assert EnvRegistry.get("missing") == nil
  end

  test "tidewave_url and tidewave_mcp_url derive loopback endpoints from port" do
    inst = %{"port" => "41042"}

    assert EnvRegistry.tidewave_url(inst) == "http://127.0.0.1:41042/tidewave"
    assert EnvRegistry.tidewave_mcp_url(inst) == "http://127.0.0.1:41042/tidewave/mcp"

    int_port = %{"port" => 41_043}
    assert EnvRegistry.tidewave_mcp_url(int_port) == "http://127.0.0.1:41043/tidewave/mcp"
  end

  test "tidewave helpers prefer explicit registry fields" do
    inst = %{
      "port" => "41042",
      "tidewave_url" => "http://custom/tidewave",
      "tidewave_mcp_url" => "http://custom/tidewave/mcp"
    }

    assert EnvRegistry.tidewave_url(inst) == "http://custom/tidewave"
    assert EnvRegistry.tidewave_mcp_url(inst) == "http://custom/tidewave/mcp"
  end

  defp write_instance!(dir, name, map) do
    path = Path.join(dir, name)
    File.write!(path, Jason.encode!(map))
  end

  defp restore_preview_home(nil), do: Application.delete_env(:casein, :preview_env_home)
  defp restore_preview_home(value), do: Application.put_env(:casein, :preview_env_home, value)
end
