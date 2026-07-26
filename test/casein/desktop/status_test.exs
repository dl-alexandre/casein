defmodule Casein.Desktop.StatusTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.Status

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "casein-status-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "runtime.json")}
  end

  test "payload carries the full status contract" do
    payload = Status.payload(4321)

    assert payload["schema"] == Status.schema_version()
    assert payload["status"] == "ready"
    assert payload["port"] == 4321
    assert payload["base_url"] == "http://127.0.0.1:4321"
    assert payload["pid"] == String.to_integer(System.pid())
    assert is_binary(payload["version"]) and payload["version"] != ""
    assert is_binary(payload["revision"]) and payload["revision"] != ""
    assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(payload["started_at"])
  end

  test "write!/read round-trips and leaves no tmp files behind", %{path: path} do
    payload = Status.payload(4321)

    assert :ok = Status.write!(path, payload)
    assert {:ok, ^payload} = Status.read(path)
    assert File.ls!(Path.dirname(path)) == ["runtime.json"]
  end

  test "read rejects unknown schemas and invalid payloads", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, Jason.encode!(%{"schema" => 999}))
    assert {:error, {:unsupported_schema, 999}} = Status.read(path)

    File.write!(path, Jason.encode!(%{"status" => "ready"}))
    assert {:error, :missing_schema} = Status.read(path)

    File.write!(path, "not json")
    assert {:error, {:invalid_json, _}} = Status.read(path)

    assert {:error, :enoent} = Status.read(path <> ".missing")
  end

  test "clear removes the file and tolerates a missing one", %{path: path} do
    assert :ok = Status.write!(path, Status.payload(1))
    assert :ok = Status.clear(path)
    refute File.exists?(path)
    assert :ok = Status.clear(path)
  end

  test "publishes on start and removes the file on graceful stop", %{path: path} do
    pid = start_supervised!({Status, port: 4567, path: path, name: nil})

    assert {:ok, payload} = Status.read(path)
    assert payload["port"] == 4567
    assert Status.current(pid) == payload

    :ok = stop_supervised!(Status)
    refute File.exists?(path)
  end

  test "resolves the port through the injected resolver", %{path: path} do
    start_supervised!(
      {Status, port_resolver: fn -> {:ok, {{127, 0, 0, 1}, 9999}} end, path: path, name: nil}
    )

    assert {:ok, %{"port" => 9999, "base_url" => "http://127.0.0.1:9999"}} = Status.read(path)
  end

  test "current/1 is nil when the server is not running" do
    assert Status.current(:no_such_status_server) == nil
  end
end
