defmodule CaseinWeb.DesktopDownloadController do
  @moduledoc "Serves only the exact desktop binaries configured by the operator."

  use CaseinWeb, :controller

  def windows(conn, _params) do
    case Casein.DesktopDownloads.fetch(:windows) do
      {:ok, download} -> send_verified_download(conn, download)
      :error -> send_resp(conn, 404, "Not found")
    end
  end

  def windows_sha256(conn, _params) do
    case Casein.DesktopDownloads.fetch(:windows) do
      {:ok, download} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, "#{download.sha256}  #{download.filename}\n")

      :error ->
        send_resp(conn, 404, "Not found")
    end
  end

  # The path is absolute operator configuration, not request input, and its bytes must match the configured SHA-256.
  # sobelow_skip ["Traversal.FileModule"]
  defp send_verified_download(conn, download) do
    expected_sha256 = download.sha256

    with {:ok, bytes} <- File.read(download.path),
         ^expected_sha256 <- :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{download.filename}"))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("accept-ranges", "bytes")
      |> send_bytes(bytes)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  # Verified executable bytes are served as attachment-only application/octet-stream, never HTML.
  # sobelow_skip ["XSS.SendResp"]
  defp send_bytes(conn, bytes) do
    size = byte_size(bytes)

    case get_req_header(conn, "range") do
      [] -> send_resp(conn, 200, bytes)
      [range] -> send_range(conn, bytes, size, range)
      _ -> range_not_satisfiable(conn, size)
    end
  end

  # This is a slice of the same verified attachment bytes, never rendered HTML.
  # sobelow_skip ["XSS.SendResp"]
  defp send_range(conn, bytes, size, "bytes=" <> range) do
    case String.split(range, "-", parts: 2) do
      [start_text, end_text] when start_text != "" ->
        with {start, ""} <- Integer.parse(start_text),
             true <- start >= 0 and start < size,
             {:ok, finish} <- range_finish(end_text, size),
             true <- finish >= start do
          length = finish - start + 1

          conn
          |> put_resp_header("content-range", "bytes #{start}-#{finish}/#{size}")
          |> send_resp(206, binary_part(bytes, start, length))
        else
          _ -> range_not_satisfiable(conn, size)
        end

      _ ->
        range_not_satisfiable(conn, size)
    end
  end

  defp send_range(conn, _bytes, size, _range), do: range_not_satisfiable(conn, size)

  defp range_finish("", size), do: {:ok, size - 1}

  defp range_finish(text, size) do
    case Integer.parse(text) do
      {finish, ""} when finish >= 0 -> {:ok, min(finish, size - 1)}
      _ -> :error
    end
  end

  defp range_not_satisfiable(conn, size) do
    conn
    |> put_resp_header("content-range", "bytes */#{size}")
    |> send_resp(416, "")
  end
end
