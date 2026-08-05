defmodule CaseinWeb.DesktopDownloadControllerTest do
  use CaseinWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:casein, :desktop_downloads)

    on_exit(fn ->
      if previous do
        Application.put_env(:casein, :desktop_downloads, previous)
      else
        Application.delete_env(:casein, :desktop_downloads)
      end
    end)

    :ok
  end

  test "serves the explicitly configured binary and publishes its SHA-256", %{conn: conn} do
    {path, sha256} = configured_binary("casein-bootstrap")

    conn = get(conn, "/downloads/windows/Casein-Setup.exe")

    assert response(conn, 200) == "casein-bootstrap"
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="Casein-Setup.exe")]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    hash_conn = get(recycle(conn), "/downloads/windows/Casein-Setup.exe.sha256")
    assert response(hash_conn, 200) == "#{sha256}  Casein-Setup.exe\n"
    assert path == Application.get_env(:casein, :desktop_downloads)[:windows][:path]
  end

  test "supports a single byte range and rejects an invalid range", %{conn: conn} do
    configured_binary("casein-bootstrap")

    ranged =
      conn |> put_req_header("range", "bytes=7-15") |> get("/downloads/windows/Casein-Setup.exe")

    assert response(ranged, 206) == "bootstrap"
    assert get_resp_header(ranged, "content-range") == ["bytes 7-15/16"]

    invalid =
      conn
      |> put_req_header("range", "bytes=99-100")
      |> get("/downloads/windows/Casein-Setup.exe")

    assert response(invalid, 416) == ""
    assert get_resp_header(invalid, "content-range") == ["bytes */16"]
  end

  test "returns 404 for a missing or mismatched SHA-256", %{conn: conn} do
    {path, _sha256} = configured_binary("casein-bootstrap")

    Application.put_env(:casein, :desktop_downloads,
      windows: [path: path, sha256: String.duplicate("0", 64)]
    )

    assert response(get(conn, "/downloads/windows/Casein-Setup.exe"), 404) == "Not found"
  end

  test "rejects a relative path", %{conn: conn} do
    Application.put_env(:casein, :desktop_downloads,
      windows: [path: "Casein-Setup.exe", sha256: String.duplicate("0", 64)]
    )

    assert response(get(conn, "/downloads/windows/Casein-Setup.exe"), 404) == "Not found"
  end

  test "rejects a configured directory", %{conn: conn} do
    directory = temp_path("casein-downloads")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    Application.put_env(:casein, :desktop_downloads,
      windows: [path: directory, sha256: String.duplicate("0", 64)]
    )

    assert response(get(conn, "/downloads/windows/Casein-Setup.exe"), 404) == "Not found"
  end

  if match?({:unix, _}, :os.type()) do
    test "rejects a configured symlink", %{conn: conn} do
      {target, sha256} = configured_binary("casein-bootstrap")
      link = temp_path("casein-setup-link")
      :ok = File.ln_s(target, link)
      on_exit(fn -> File.rm(link) end)
      Application.put_env(:casein, :desktop_downloads, windows: [path: link, sha256: sha256])

      assert response(get(conn, "/downloads/windows/Casein-Setup.exe"), 404) == "Not found"
    end
  end

  defp configured_binary(bytes) do
    path = temp_path("casein-setup") <> ".exe"
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    sha256 = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    Application.put_env(:casein, :desktop_downloads, windows: [path: path, sha256: sha256])
    {path, sha256}
  end

  defp temp_path(prefix),
    do: Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
end
