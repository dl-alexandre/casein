defmodule CaseinWeb.DesktopDownloadControllerTest do
  use CaseinWeb.ConnCase, async: false

  @contents "casein-bootstrap"

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
    {path, sha256} = configured_binary(@contents)

    conn = get(conn, "/downloads/windows/Casein-Setup.exe")

    assert response(conn, 200) == @contents
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "etag") == [~s("#{sha256}")]

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="Casein-Setup.exe")]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    hash_conn = get(recycle(conn), "/downloads/windows/Casein-Setup.exe.sha256")
    assert response(hash_conn, 200) == "#{sha256}  Casein-Setup.exe\n"
    assert path == Application.get_env(:casein, :desktop_downloads)[:windows][:path]
  end

  test "supports a single byte range and rejects an unsatisfiable one", %{conn: conn} do
    configured_binary(@contents)

    ranged = ranged_get(conn, "bytes=7-15")

    assert response(ranged, 206) == "bootstrap"
    assert get_resp_header(ranged, "content-range") == ["bytes 7-15/16"]

    open_ended = ranged_get(conn, "bytes=7-")
    assert response(open_ended, 206) == "bootstrap"
    assert get_resp_header(open_ended, "content-range") == ["bytes 7-15/16"]

    invalid = ranged_get(conn, "bytes=99-100")
    assert response(invalid, 416) == ""
    assert get_resp_header(invalid, "content-range") == ["bytes */16"]
  end

  test "supports a suffix range for the final bytes", %{conn: conn} do
    configured_binary(@contents)

    ranged = ranged_get(conn, "bytes=-9")

    assert response(ranged, 206) == "bootstrap"
    assert get_resp_header(ranged, "content-range") == ["bytes 7-15/16"]
  end

  test "clamps a suffix range longer than the file", %{conn: conn} do
    configured_binary(@contents)

    ranged = ranged_get(conn, "bytes=-999")

    assert response(ranged, 206) == @contents
    assert get_resp_header(ranged, "content-range") == ["bytes 0-15/16"]
  end

  test "ignores a malformed range and serves the whole file", %{conn: conn} do
    configured_binary(@contents)

    assert response(ranged_get(conn, "bytes=abc"), 200) == @contents
    assert response(ranged_get(conn, "widgets=0-5"), 200) == @contents
  end

  test "serves the whole file when If-Range does not match the current build", %{conn: conn} do
    {_path, sha256} = configured_binary(@contents)

    stale =
      conn
      |> put_req_header("range", "bytes=7-15")
      |> put_req_header("if-range", ~s("#{String.duplicate("0", 64)}"))
      |> get("/downloads/windows/Casein-Setup.exe")

    assert response(stale, 200) == @contents

    current =
      conn
      |> put_req_header("range", "bytes=7-15")
      |> put_req_header("if-range", ~s("#{sha256}"))
      |> get("/downloads/windows/Casein-Setup.exe")

    assert response(current, 206) == "bootstrap"
  end

  test "both routes refuse a file that no longer matches its configured SHA-256", %{conn: conn} do
    {path, _sha256} = configured_binary(@contents)

    Application.put_env(:casein, :desktop_downloads,
      windows: [path: path, sha256: String.duplicate("0", 64)]
    )

    assert response(get(conn, "/downloads/windows/Casein-Setup.exe"), 404) == "Not found"

    assert response(get(recycle(conn), "/downloads/windows/Casein-Setup.exe.sha256"), 404) ==
             "Not found"
  end

  test "returns 404 when no SHA-256 is configured", %{conn: conn} do
    {path, _sha256} = configured_binary(@contents)
    Application.put_env(:casein, :desktop_downloads, windows: [path: path, sha256: nil])

    assert response(get(conn, "/downloads/windows/Casein-Setup.exe"), 404) == "Not found"
  end

  test "returns 404 when the operator has not configured a binary", %{conn: conn} do
    Application.put_env(:casein, :desktop_downloads, windows: [path: nil, sha256: nil])
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
      {target, sha256} = configured_binary(@contents)
      link = temp_path("casein-setup-link")
      :ok = File.ln_s(target, link)
      on_exit(fn -> File.rm(link) end)
      Application.put_env(:casein, :desktop_downloads, windows: [path: link, sha256: sha256])

      assert response(get(conn, "/downloads/windows/Casein-Setup.exe"), 404) == "Not found"
    end
  end

  defp ranged_get(conn, range) do
    conn |> put_req_header("range", range) |> get("/downloads/windows/Casein-Setup.exe")
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
